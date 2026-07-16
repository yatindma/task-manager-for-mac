import Darwin
import Foundation

/// Samples physical and swap memory, matching Activity Monitor's definitions.
final class MemorySampler {

    private var stats = MemoryStats()
    private var hardwareLoaded = false

    init() {}

    func sample() -> MemoryStats {
        if !hardwareLoaded {
            stats.totalBytes = sysctlUInt64("hw.memsize") ?? 0
            loadModuleInfo()
            hardwareLoaded = true
        }

        readVMStatistics()
        readSwap()
        stats.history.push(stats.usedPercent)
        return stats
    }

    // MARK: - Physical memory

    private func readVMStatistics() {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let page = UInt64(vm_kernel_page_size)

        let wired = UInt64(info.wire_count) * page
        let compressed = UInt64(info.compressor_page_count) * page
        let purgeable = UInt64(info.purgeable_count) * page
        let external = UInt64(info.external_page_count) * page
        let internalPages = UInt64(info.internal_page_count) * page
        let free = UInt64(info.free_count &- info.speculative_count) * page

        // Activity Monitor's "App Memory" is anonymous memory minus what the system
        // can throw away on demand; "Memory Used" is that plus wired plus compressed.
        let appMemory = internalPages > purgeable ? internalPages - purgeable : 0

        stats.wiredBytes = wired
        stats.compressedBytes = compressed
        stats.cachedBytes = external + purgeable
        stats.usedBytes = min(appMemory + wired + compressed, stats.totalBytes)
        stats.availableBytes = stats.totalBytes > stats.usedBytes
            ? stats.totalBytes - stats.usedBytes
            : free
    }

    private func readSwap() {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        stats.swapUsedBytes = usage.xsu_used
        stats.swapTotalBytes = usage.xsu_total
    }

    // MARK: - Module description

    /// Speed / form factor / slots come from system_profiler, which takes seconds to
    /// run. It never changes while the machine is up, so it is read exactly once.
    private func loadModuleInfo() {
        guard let output = runSystemProfiler() else { return }

        var speeds: [Int] = []
        var formFactors: [String] = []
        var occupiedSlots = 0
        var totalSlots = 0

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = value(after: "Speed:", in: line) {
                if value.localizedCaseInsensitiveContains("empty") { continue }
                let digits = value.prefix { $0.isNumber }
                if let mhz = Int(digits) {
                    // Apple Silicon reports LPDDR speeds in MHz already; Intel may say "2667 MHz".
                    speeds.append(mhz)
                }
            } else if let value = value(after: "Type:", in: line) {
                if !value.localizedCaseInsensitiveContains("empty") {
                    formFactors.append(value)
                }
            } else if let value = value(after: "Size:", in: line) {
                totalSlots += 1
                if !value.localizedCaseInsensitiveContains("empty") { occupiedSlots += 1 }
            }
        }

        stats.speedMHz = speeds.max() ?? 0
        stats.formFactor = formFactors.first ?? ""
        if totalSlots > 0 {
            stats.slotsUsed = "\(occupiedSlots) of \(totalSlots)"
        } else {
            // Apple Silicon solders memory into the package and reports no slots at all.
            stats.slotsUsed = ""
            if stats.formFactor.isEmpty, let type = firstValue(after: "Memory Type:", in: output) {
                stats.formFactor = type
            }
            if stats.speedMHz == 0, let manufacturer = firstValue(after: "Manufacturer:", in: output),
               stats.formFactor.isEmpty {
                stats.formFactor = manufacturer
            }
        }
    }

    private func runSystemProfiler() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPMemoryDataType", "-detailLevel", "mini"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private func value(after key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        return String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }

    private func firstValue(after key: String, in output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = value(after: key, in: line), !value.isEmpty { return value }
        }
        return nil
    }

    private func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
