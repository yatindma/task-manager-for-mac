import Darwin
import Foundation
import IOKit

/// Samples overall and per-core CPU load from `host_processor_info` deltas.
///
/// Owns the previous tick counters, so `sample()` must be called from one thread
/// at a time (SystemMonitor serialises this on its sampling queue).
final class CPUSampler {

    private var stats = CPUStats()
    private var previousTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var staticsLoaded = false

    init() {}

    func sample() -> CPUStats {
        if !staticsLoaded {
            loadStatics()
            staticsLoaded = true
        }

        if let ticks = readTicks() {
            applyDelta(ticks)
            previousTicks = ticks
        }

        stats.uptime = uptimeSeconds()
        stats.history.push(stats.usage)
        return stats
    }

    // MARK: - Per-core ticks

    private func readTicks() -> [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }

        // The kernel hands us a vm_allocate'd array; we must hand it back.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        var ticks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        ticks.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            ticks.append((
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        return ticks
    }

    private func applyDelta(_ ticks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]) {
        guard previousTicks.count == ticks.count else {
            // First sample (or core count changed under us): no delta to report yet.
            stats.perCore = Array(repeating: 0, count: ticks.count)
            stats.usage = 0
            return
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(ticks.count)
        var busyTotal: Double = 0
        var allTotal: Double = 0

        for (now, before) in zip(ticks, previousTicks) {
            let user = Double(now.user &- before.user)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let nice = Double(now.nice &- before.nice)

            let busy = user + system + nice
            let total = busy + idle
            perCore.append(total > 0 ? busy / total * 100 : 0)
            busyTotal += busy
            allTotal += total
        }

        stats.perCore = perCore
        stats.usage = allTotal > 0 ? busyTotal / allTotal * 100 : 0
    }

    // MARK: - Static description

    private func loadStatics() {
        stats.model = sysctlString("machdep.cpu.brand_string") ?? "Unknown processor"
        stats.cores = sysctlInt("hw.physicalcpu").map(Int.init) ?? 0
        stats.logicalProcessors = sysctlInt("hw.logicalcpu").map(Int.init) ?? 0

        // Intel Macs expose hw.cpufrequency_max in Hz. Apple Silicon does not publish
        // any frequency sysctl; its P-core max clock instead lives in the pmgr
        // DVFS table in the IORegistry. Brand string GHz is the last-resort fallback.
        if let hz = sysctlInt("hw.cpufrequency_max"), hz > 0 {
            stats.maxSpeedGHz = Double(hz) / 1_000_000_000
        } else if let hz = pCoreMaxHzFromIORegistry(), hz > 0 {
            stats.maxSpeedGHz = Double(hz) / 1_000_000_000
        } else {
            stats.maxSpeedGHz = ghzFromBrandString(stats.model)
        }
        stats.speedGHz = stats.maxSpeedGHz
    }

    /// Reads the P-core DVFS table (`voltage-states5-sram`) off the `pmgr` node
    /// under `AppleARMIODevice`. The table is packed (freq: UInt32 Hz, voltage:
    /// UInt32 mV) pairs in ascending frequency order; the last pair is the max.
    private func pCoreMaxHzFromIORegistry() -> UInt64? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var foundHz: UInt64?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if foundHz == nil,
               let property = IORegistryEntryCreateCFProperty(service, "voltage-states5-sram" as CFString, kCFAllocatorDefault, 0),
               let data = property.takeRetainedValue() as? Data,
               data.count >= 8, data.count % 8 == 0 {
                let lastPairOffset = data.count - 8
                let freqHz = data.subdata(in: lastPairOffset..<(lastPairOffset + 4))
                    .withUnsafeBytes { $0.load(as: UInt32.self) }
                // Sanity check: P-core clocks on shipping Apple Silicon fall well within 0.5–10 GHz.
                if freqHz > 500_000_000, freqHz < UInt32.max {
                    foundHz = UInt64(freqHz)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return foundHz
    }

    /// Pulls "2.40GHz" / "3.2 GHz" out of an Intel brand string.
    private func ghzFromBrandString(_ brand: String) -> Double {
        guard let range = brand.range(of: #"([0-9]+\.[0-9]+)\s*GHz"#, options: [.regularExpression, .caseInsensitive]) else {
            return 0
        }
        let match = brand[range]
        let digits = match.prefix { $0.isNumber || $0 == "." }
        return Double(digits) ?? 0
    }

    private func uptimeSeconds() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else {
            return 0
        }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec) - Double(boot.tv_usec) / 1_000_000
    }

    // MARK: - sysctl helpers

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespaces)
    }

    private func sysctlInt(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }

        // Some keys are 32-bit; retry narrow.
        var narrow: UInt32 = 0
        var narrowSize = MemoryLayout<UInt32>.stride
        if sysctlbyname(name, &narrow, &narrowSize, nil, 0) == 0 { return UInt64(narrow) }
        return nil
    }
}
