import Foundation
import IOKit

/// GPU utilization and memory, read from each accelerator's
/// "PerformanceStatistics" dictionary in the IORegistry.
///
/// Apple Silicon publishes "Device Utilization %"; older Intel/AMD drivers use
/// "GPU Core Utilization" (a 0...100_000_000 scale), so both are handled.
final class GPUSampler {

    private var histories: [String: RingBuffer] = [:]

    /// VRAM totals come from `system_profiler`, which takes hundreds of
    /// milliseconds. The answer is fixed for the life of the machine.
    private var vramTotals: [String: UInt64] = [:]
    private var profilerNames: [String] = []
    private var profilerLoaded = false

    func sample() -> [GPUStats] {
        var result: [GPUStats] = []
        var seen: Set<String> = []

        for accelerator in accelerators() {
            defer { IOObjectRelease(accelerator) }
            guard let name = deviceName(of: accelerator), !seen.contains(name) else { continue }
            seen.insert(name)

            let statistics = property(accelerator, "PerformanceStatistics") as? [String: Any] ?? [:]
            let utilization = self.utilization(from: statistics)

            var history = histories[name] ?? RingBuffer()
            history.push(utilization)
            histories[name] = history

            let isIntegrated = self.isIntegrated(accelerator)
            // Apple Silicon has no dedicated VRAM: the driver reports the slice
            // of unified system memory it currently holds.
            let vramUsed = (statistics["In use system memory"] as? NSNumber)?.uint64Value ?? 0

            result.append(
                GPUStats(
                    name: name,
                    utilization: utilization,
                    vramUsedBytes: vramUsed,
                    vramTotalBytes: vramTotal(for: name, isIntegrated: isIntegrated),
                    isIntegrated: isIntegrated,
                    history: history
                )
            )
        }

        histories = histories.filter { seen.contains($0.key) }

        if result.isEmpty {
            // Never hand back an empty list: the Performance tab still needs a
            // GPU row, even on a machine whose driver publishes no statistics.
            loadProfilerIfNeeded()
            let name = profilerNames.first ?? "GPU"
            var history = histories[name] ?? RingBuffer()
            history.push(0)
            histories[name] = history
            result.append(
                GPUStats(
                    name: name,
                    utilization: 0,
                    vramUsedBytes: 0,
                    vramTotalBytes: vramTotal(for: name, isIntegrated: true),
                    isIntegrated: true,
                    history: history
                )
            )
        }

        return result
    }

    // MARK: - IORegistry

    /// `IOAccelerator` is the common superclass; matching it covers the Apple
    /// Silicon `AGXAccelerator` and the Intel/AMD accelerators alike.
    private func accelerators() -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var entries: [io_registry_entry_t] = []
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            entries.append(entry)
        }
        return entries
    }

    private func utilization(from statistics: [String: Any]) -> Double {
        if let device = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue {
            return min(max(device, 0), 100)
        }
        if let core = (statistics["GPU Core Utilization"] as? NSNumber)?.doubleValue {
            // Intel/AMD report this in hundredths of a nanosecond-percent, i.e.
            // 100% is 10^8.
            return min(max(core / 1_000_000, 0), 100)
        }
        if let renderer = (statistics["Renderer Utilization %"] as? NSNumber)?.doubleValue {
            return min(max(renderer, 0), 100)
        }
        return 0
    }

    private func deviceName(of accelerator: io_registry_entry_t) -> String? {
        for key in ["IOGPUDeviceName", "model"] {
            if let text = string(property(accelerator, key)), !text.isEmpty { return text }
        }
        // Fall back to the parent IOService, which is where a PCI GPU carries
        // its model string.
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(accelerator, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(parent) }
        for key in ["IOGPUDeviceName", "model"] {
            if let text = string(property(parent, key)), !text.isEmpty { return text }
        }
        return nil
    }

    /// The driver publishes strings as either CFString or raw CFData bytes.
    private func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let data = value as? Data {
            let trimmed = data.prefix { $0 != 0 }
            return String(data: trimmed, encoding: .utf8)
        }
        return nil
    }

    private func isIntegrated(_ accelerator: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(accelerator, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return true
        }
        defer { IOObjectRelease(parent) }
        // A discrete card hangs off PCI and advertises its own VRAM.
        if property(parent, "VRAM,totalMB") != nil { return false }
        if IOObjectConformsTo(parent, "IOPCIDevice") != 0 { return false }
        return true
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let ref = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return ref.takeRetainedValue()
    }

    // MARK: - VRAM totals

    private func vramTotal(for name: String, isIntegrated: Bool) -> UInt64 {
        loadProfilerIfNeeded()
        if let total = vramTotals[name] { return total }
        // Unified memory: the whole of RAM is addressable by the GPU, which is
        // what "shared" means in system_profiler's own report.
        if isIntegrated { return physicalMemory() }
        return 0
    }

    private func physicalMemory() -> UInt64 {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &size, &length, nil, 0) == 0 else { return 0 }
        return size
    }

    private func loadProfilerIfNeeded() {
        guard !profilerLoaded else { return }
        profilerLoaded = true

        guard let data = runSystemProfiler(dataType: "SPDisplaysDataType"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPDisplaysDataType"] as? [[String: Any]]
        else { return }

        for entry in entries {
            let name = (entry["sppci_model"] as? String) ?? (entry["_name"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            profilerNames.append(name)
            let text = (entry["spdisplays_vram"] as? String) ?? (entry["spdisplays_vram_shared"] as? String)
            if let bytes = megabytes(from: text) { vramTotals[name] = bytes }
        }
    }

    /// system_profiler formats VRAM as "8 GB" or "1536 MB".
    private func megabytes(from text: String?) -> UInt64? {
        guard let text else { return nil }
        let parts = text.split(separator: " ")
        guard let value = Double(parts.first ?? "") else { return nil }
        let unit = parts.count > 1 ? parts[1].uppercased() : "MB"
        switch unit {
        case "GB": return UInt64(value * 1024 * 1024 * 1024)
        case "MB": return UInt64(value * 1024 * 1024)
        default: return nil
        }
    }

    private func runSystemProfiler(dataType: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", dataType]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
