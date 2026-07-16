import Foundation
import IOKit
import IOKit.storage

/// Per-physical-disk I/O rates and busy time, read from the IORegistry.
///
/// Every `IOBlockStorageDriver` publishes a "Statistics" dictionary of counters
/// that run monotonically from boot. Rates come from deltas between samples, so
/// the first `sample()` reports zero rates for a disk it has not seen before.
final class DiskSampler {

    /// Cumulative counters plus the timestamp they were read at.
    private struct Counters {
        var bytesRead: UInt64
        var bytesWritten: UInt64
        /// Nanoseconds the driver spent servicing reads/writes, cumulative.
        var busyTimeNanos: UInt64
        var timestamp: Date
    }

    /// Keyed by BSD name ("disk0"). Carries the counters and the graph history
    /// forward, since `DiskStats` is a fresh value on every sample.
    private var previous: [String: Counters] = [:]
    private var histories: [String: (total: RingBuffer, read: RingBuffer, write: RingBuffer)] = [:]

    /// Static per-disk facts. The IORegistry walk for these is comparatively
    /// expensive and the answers never change while the disk is attached.
    private var identityCache: [String: (model: String, capacity: UInt64, isSSD: Bool)] = [:]

    func sample() -> [DiskStats] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOBlockStorageDriverClass)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        let now = Date()
        var result: [DiskStats] = []
        var seen: Set<String> = []

        while case let driver = IOIteratorNext(iterator), driver != IO_OBJECT_NULL {
            defer { IOObjectRelease(driver) }

            guard let bsdName = wholeMediaBSDName(driver: driver), !seen.contains(bsdName) else { continue }
            guard let stats = statistics(of: driver) else { continue }
            seen.insert(bsdName)

            let identity = identity(driver: driver, bsdName: bsdName)
            let current = Counters(
                bytesRead: stats.bytesRead,
                bytesWritten: stats.bytesWritten,
                busyTimeNanos: stats.totalTimeRead &+ stats.totalTimeWrite,
                timestamp: now
            )

            var readRate = 0.0
            var writeRate = 0.0
            var activePercent = 0.0

            if let last = previous[bsdName] {
                let elapsed = current.timestamp.timeIntervalSince(last.timestamp)
                if elapsed > 0 {
                    readRate = Double(current.bytesRead &- last.bytesRead) / elapsed
                    writeRate = Double(current.bytesWritten &- last.bytesWritten) / elapsed
                    // Service time can exceed wall-clock when requests overlap,
                    // so the busy fraction is clamped the way Windows caps it.
                    let busy = Double(current.busyTimeNanos &- last.busyTimeNanos)
                    activePercent = min(max(busy / (elapsed * 1_000_000_000) * 100, 0), 100)
                }
            }
            previous[bsdName] = current

            var history = histories[bsdName] ?? (RingBuffer(), RingBuffer(), RingBuffer())
            history.total.push(activePercent)
            history.read.push(readRate)
            history.write.push(writeRate)
            histories[bsdName] = history

            result.append(
                DiskStats(
                    name: bsdName,
                    model: identity.model,
                    activePercent: activePercent,
                    readRate: readRate,
                    writeRate: writeRate,
                    capacityBytes: identity.capacity,
                    isSSD: identity.isSSD,
                    history: history.total,
                    readHistory: history.read,
                    writeHistory: history.write
                )
            )
        }

        // Drop state for disks that have been ejected.
        previous = previous.filter { seen.contains($0.key) }
        histories = histories.filter { seen.contains($0.key) }
        identityCache = identityCache.filter { seen.contains($0.key) }

        return result.sorted { $0.name < $1.name }
    }

    // MARK: - IORegistry reads

    private func statistics(of driver: io_registry_entry_t) -> (
        bytesRead: UInt64, bytesWritten: UInt64, totalTimeRead: UInt64, totalTimeWrite: UInt64
    )? {
        guard let dict = property(driver, kIOBlockStorageDriverStatisticsKey) as? [String: Any] else {
            return nil
        }
        func value(_ key: String) -> UInt64 {
            (dict[key] as? NSNumber)?.uint64Value ?? 0
        }
        return (
            value(kIOBlockStorageDriverStatisticsBytesReadKey),
            value(kIOBlockStorageDriverStatisticsBytesWrittenKey),
            value(kIOBlockStorageDriverStatisticsTotalReadTimeKey),
            value(kIOBlockStorageDriverStatisticsTotalWriteTimeKey)
        )
    }

    /// The driver's direct child is the whole-disk `IOMedia`; its BSD name is
    /// the stable identifier we key everything on.
    private func wholeMediaBSDName(driver: io_registry_entry_t) -> String? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(children) }

        while case let media = IOIteratorNext(children), media != IO_OBJECT_NULL {
            defer { IOObjectRelease(media) }
            guard (property(media, kIOMediaWholeKey) as? NSNumber)?.boolValue == true else { continue }
            if let name = property(media, kIOBSDNameKey) as? String { return name }
        }
        return nil
    }

    private func identity(driver: io_registry_entry_t, bsdName: String) -> (model: String, capacity: UInt64, isSSD: Bool) {
        if let cached = identityCache[bsdName] { return cached }

        var capacity: UInt64 = 0
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS {
            while case let media = IOIteratorNext(children), media != IO_OBJECT_NULL {
                defer { IOObjectRelease(media) }
                if (property(media, kIOMediaWholeKey) as? NSNumber)?.boolValue == true {
                    capacity = (property(media, kIOMediaSizeKey) as? NSNumber)?.uint64Value ?? 0
                    break
                }
            }
            IOObjectRelease(children)
        }

        // "Device Characteristics" lives on the parent IOBlockStorageDevice.
        var model = ""
        var isSSD = true
        var device: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS {
            if let characteristics = property(device, kIOPropertyDeviceCharacteristicsKey) as? [String: Any] {
                let vendor = (characteristics[kIOPropertyVendorNameKey] as? String)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let product = (characteristics[kIOPropertyProductNameKey] as? String)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                model = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
                if let medium = characteristics[kIOPropertyMediumTypeKey] as? String {
                    isSSD = medium == kIOPropertyMediumTypeSolidStateKey
                }
            }
            IOObjectRelease(device)
        }
        if model.isEmpty { model = bsdName }

        let identity = (model: model, capacity: capacity, isSSD: isSSD)
        identityCache[bsdName] = identity
        return identity
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let ref = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return ref.takeRetainedValue()
    }
}
