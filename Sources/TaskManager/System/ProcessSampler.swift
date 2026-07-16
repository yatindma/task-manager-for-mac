import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Samples every process on the machine and returns the grouped tree the
/// Processes tab renders.
///
/// Callable off the main thread. Owns its own delta state (CPU ticks, disk
/// byte counters) across calls, so it must be sampled at a steady cadence.
final class ProcessSampler {

    // MARK: - Per-pid state

    /// Facts about a process that never change while it lives. Keyed by pid but
    /// validated against `startTime`, so a recycled pid drops the stale entry.
    private struct StaticInfo {
        let startTime: Date
        let name: String
        let path: String
        let user: String
        let uid: uid_t
        let parentPID: pid_t
    }

    /// Counters we diff between samples to turn totals into rates.
    private struct Deltas {
        var cpuNanos: UInt64
        var diskBytes: UInt64
        var timestamp: TimeInterval
    }

    private var staticInfo: [pid_t: StaticInfo] = [:]
    private var deltas: [pid_t: Deltas] = [:]
    private var iconsByPath: [String: NSImage] = [:]

    /// Scratch buffer for the KERN_PROC_ALL snapshot, grown but never shrunk.
    private var procBuffer: [kinfo_proc] = []

    private let activeCPUs = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))

    /// proc_taskinfo's CPU totals are mach absolute time units, NOT nanoseconds —
    /// a distinction that is invisible on Intel (timebase 1:1) and 41.67x wrong on
    /// Apple Silicon (125/3). Measured against a pinned core: without this, a process
    /// burning 100% of a core reports 2.4%.
    private static let machToNanos: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    private let appCache = RunningAppCache()
    private let netRates = NettopRates()
    private let hangProbe = HangProbe()

    init() {}

    // MARK: - Sample

    func sample() -> [ProcRow] {
        appCache.refreshIfNeeded()
        netRates.refreshIfNeeded()

        let nowMono = ProcessInfo.processInfo.systemUptime
        let procs = allProcesses()
        guard !procs.isEmpty else { return [] }

        let apps = appCache.snapshot()
        let network = netRates.snapshot()
        hangProbe.refreshIfNeeded(regularApps: apps.compactMap { $0.value.isRegular ? $0.key : nil })
        let hung = hangProbe.snapshot()

        var live = Set<pid_t>()
        live.reserveCapacity(procs.count)
        var flat: [pid_t: ProcRow] = [:]
        flat.reserveCapacity(procs.count)

        for kp in procs {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            live.insert(pid)

            let started = Self.startDate(of: kp)
            let info = staticInfo(for: pid, kp: kp, started: started)

            var taskInfo = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let gotTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskSize) == taskSize

            let cpuNanos = gotTask ? taskInfo.pti_total_user &+ taskInfo.pti_total_system : 0
            let threads = gotTask ? Int(taskInfo.pti_threadnum) : 0

            // phys_footprint is what Activity Monitor reports; resident_size
            // over-counts shared pages. Fall back only if rusage is denied.
            var memory = gotTask ? taskInfo.pti_resident_size : 0
            var diskBytes: UInt64 = 0
            if let usage = Self.rusage(pid) {
                memory = usage.ri_phys_footprint
                diskBytes = usage.ri_diskio_bytesread &+ usage.ri_diskio_byteswritten
            }

            // First sighting of a pid has no baseline, so its rates read 0.
            var cpuPercent = 0.0
            var diskRate = 0.0
            if let prev = deltas[pid] {
                let elapsed = nowMono - prev.timestamp
                if elapsed > 0.01 {
                    if cpuNanos > prev.cpuNanos {
                        let ticks = Double(cpuNanos - prev.cpuNanos)
                        let seconds = ticks * Self.machToNanos / 1_000_000_000
                        // Normalised across all cores: 0...100 total, the way the
                        // Windows Processes tab reports it (not per-core).
                        cpuPercent = min(seconds / elapsed / activeCPUs * 100, 100)
                    }
                    if diskBytes > prev.diskBytes {
                        diskRate = Double(diskBytes - prev.diskBytes) / elapsed
                    }
                }
            }
            deltas[pid] = Deltas(cpuNanos: cpuNanos, diskBytes: diskBytes, timestamp: nowMono)
            ProcessPowerTrend.shared.update(pid: pid, cpuPercent: cpuPercent)

            let app = apps[pid]
            let kind = Self.classify(uid: info.uid, path: info.path, isRegularApp: app?.isRegular ?? false)

            let status: ProcStatus
            if kp.kp_proc.p_stat == SSTOP {
                status = .suspended
            } else if hung.contains(pid) {
                status = .notResponding
            } else {
                status = .running
            }

            flat[pid] = ProcRow(
                pid: pid,
                parentPID: info.parentPID,
                name: info.name,
                displayName: app?.localizedName ?? info.name,
                kind: kind,
                status: status,
                user: info.user,
                path: info.path,
                cpu: cpuPercent,
                memoryBytes: memory,
                diskRate: diskRate,
                networkRate: network[pid] ?? 0,
                // macOS exposes no per-process GPU utilisation through any
                // public API, so this stays 0 rather than being faked.
                gpu: 0,
                threads: threads,
                handles: Self.openFileDescriptors(pid),
                startTime: info.startTime,
                icon: app.flatMap { icon(for: $0) }
            )
        }

        prune(live: live)
        return tree(from: flat)
    }

    // MARK: - Enumeration

    private func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The table can grow between sizing and reading; ask for headroom.
        let slack = size + size / 8
        let count = slack / MemoryLayout<kinfo_proc>.stride + 1
        if procBuffer.count < count {
            procBuffer = Array(repeating: kinfo_proc(), count: count)
        }

        var read = procBuffer.count * MemoryLayout<kinfo_proc>.stride
        let ok = procBuffer.withUnsafeMutableBufferPointer { buf -> Bool in
            sysctl(&mib, 4, buf.baseAddress, &read, nil, 0) == 0
        }
        guard ok else { return [] }
        return Array(procBuffer.prefix(read / MemoryLayout<kinfo_proc>.stride))
    }

    // MARK: - Static per-pid facts

    private func staticInfo(for pid: pid_t, kp: kinfo_proc, started: Date) -> StaticInfo {
        if let cached = staticInfo[pid], cached.startTime == started {
            return cached
        }

        let uid = kp.kp_eproc.e_ucred.cr_uid
        let info = StaticInfo(
            startTime: started,
            name: Self.processName(pid, kp: kp),
            path: Self.executablePath(pid),
            user: Self.username(for: uid),
            uid: uid,
            parentPID: kp.kp_eproc.e_ppid
        )
        staticInfo[pid] = info
        return info
    }

    private func prune(live: Set<pid_t>) {
        if staticInfo.count != live.count {
            staticInfo = staticInfo.filter { live.contains($0.key) }
        }
        if deltas.count != live.count {
            deltas = deltas.filter { live.contains($0.key) }
        }
        ProcessPowerTrend.shared.prune(live: live)
    }

    // MARK: - Tree

    /// Nests helper processes under the app that owns them, the way Windows
    /// groups a browser's renderers under the browser row.
    private func tree(from flat: [pid_t: ProcRow]) -> [ProcRow] {
        var appAncestor: [pid_t: pid_t?] = [:]
        appAncestor.reserveCapacity(flat.count)

        // Memoised walk up parentPID: each pid resolves once, so the whole
        // pass stays linear even with deep helper chains.
        func ancestor(of pid: pid_t) -> pid_t? {
            if let known = appAncestor[pid] { return known }
            appAncestor[pid] = pid_t?.none   // cycle / in-progress guard
            guard let row = flat[pid] else { return nil }
            var result: pid_t?
            if let parent = flat[row.parentPID], parent.pid != pid {
                result = parent.kind == .app ? parent.pid : ancestor(of: parent.pid)
            }
            appAncestor[pid] = result
            return result
        }

        var childrenOf: [pid_t: [ProcRow]] = [:]
        var roots: [ProcRow] = []
        for (pid, row) in flat {
            if let parent = ancestor(of: pid), parent != pid {
                childrenOf[parent, default: []].append(row)
            } else {
                roots.append(row)
            }
        }

        for i in roots.indices {
            if var kids = childrenOf[roots[i].pid] {
                kids.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                roots[i].children = kids
            }
        }

        roots.sort {
            $0.kind == $1.kind
                ? $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                : $0.kind < $1.kind
        }
        return roots
    }

    // MARK: - Icons

    private func icon(for app: RunningAppCache.Info) -> NSImage? {
        guard let path = app.bundlePath else { return app.icon }
        if let cached = iconsByPath[path] { return cached }
        guard let image = app.icon else { return nil }
        iconsByPath[path] = image
        return image
    }

    // MARK: - libproc helpers

    private static func startDate(of kp: kinfo_proc) -> Date {
        let tv = kp.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private static func executablePath(_ pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro Swift cannot import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        // Denied for processes we don't own; the name still resolves.
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func processName(_ pid: pid_t, kp: kinfo_proc) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        // p_comm is truncated to MAXCOMLEN and is not guaranteed to be
        // NUL-terminated when it fills the field, so stop at the first NUL
        // rather than using String(cString:).
        return withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return ok == 0 ? info : nil
    }

    /// macOS has no Windows "handle" concept. The open file-descriptor count is
    /// the honest analogue, so that is what the Handles column shows.
    private static func openFileDescriptors(_ pid: pid_t) -> Int {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return 0 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
    }

    private static func username(for uid: uid_t) -> String {
        if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
            return String(cString: name)
        }
        return String(uid)
    }

    private static func classify(uid: uid_t, path: String, isRegularApp: Bool) -> ProcKind {
        if isRegularApp { return .app }
        if uid == 0 { return .system }
        for prefix in ["/System", "/usr/libexec", "/sbin"] where path.hasPrefix(prefix) {
            return .system
        }
        return .background
    }
}

// MARK: - Running application cache

/// Mirrors NSWorkspace's app list into a lock-protected snapshot the sampler can
/// read off the main thread. AppKit's own list must only be touched on main.
private final class RunningAppCache {

    struct Info {
        let localizedName: String
        let bundlePath: String?
        let isRegular: Bool
        let icon: NSImage?
    }

    private let lock = NSLock()
    private var apps: [pid_t: Info] = [:]
    private var refreshing = false

    func snapshot() -> [pid_t: Info] {
        lock.lock()
        defer { lock.unlock() }
        return apps
    }

    func refreshIfNeeded() {
        lock.lock()
        let needsBlockingFirstRead = apps.isEmpty
        let alreadyRefreshing = refreshing
        if !alreadyRefreshing { refreshing = true }
        lock.unlock()
        guard !alreadyRefreshing else { return }

        if Thread.isMainThread {
            store(Self.read())
        } else if needsBlockingFirstRead {
            // Only on the very first sample, so the initial frame already has
            // app names and icons. Main is never waiting on the sampler.
            DispatchQueue.main.sync { self.store(Self.read()) }
        } else {
            DispatchQueue.main.async { self.store(Self.read()) }
        }
    }

    private func store(_ value: [pid_t: Info]) {
        lock.lock()
        apps = value
        refreshing = false
        lock.unlock()
    }

    /// Must be called on the main thread — NSWorkspace's app list is main-only.
    private static func read() -> [pid_t: Info] {
        var result: [pid_t: Info] = [:]
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier > 0 {
            result[app.processIdentifier] = Info(
                localizedName: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                bundlePath: app.bundleURL?.path,
                isRegular: app.activationPolicy == .regular,
                icon: app.icon
            )
        }
        return result
    }
}

// MARK: - Not-responding detection

/// Windows reads "not responding" straight from the window manager. macOS ships
/// no public equivalent (Activity Monitor uses a private CoreGraphics call), so
/// the honest public substitute is an Accessibility ping with a short timeout:
/// AX messages are serviced on an app's main thread, so a wedged app times out.
///
/// Needs Accessibility permission. Without it every app simply reads as running.
private final class HangProbe {

    private let interval: TimeInterval = 2.0
    private let timeout: Float = 0.25
    private let queue = DispatchQueue(label: "TaskManager.hangProbe", qos: .utility)
    private let lock = NSLock()
    private var hung: Set<pid_t> = []
    private var lastRun: TimeInterval = -.greatestFiniteMagnitude
    private var running = false

    func snapshot() -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return hung
    }

    func refreshIfNeeded(regularApps: [pid_t]) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let due = !running && now - lastRun >= interval
        if due {
            running = true
            lastRun = now
        }
        lock.unlock()
        guard due, !regularApps.isEmpty, AXIsProcessTrusted() else {
            if due {
                lock.lock()
                hung.removeAll(keepingCapacity: true)
                running = false
                lock.unlock()
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            var result: Set<pid_t> = []
            for pid in regularApps where self.isHung(pid) {
                result.insert(pid)
            }
            self.lock.lock()
            self.hung = result
            self.running = false
            self.lock.unlock()
        }
    }

    private func isHung(_ pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        // Only a timeout means wedged; every other error (no title, not AX-aware,
        // sandboxed) just means we cannot tell, which is not "not responding".
        return error == .cannotComplete
    }
}

// MARK: - Per-process network rates

/// Wraps `nettop`, which is a subprocess and far too costly to spawn per tick.
/// Runs on a background queue at ~2 s and caches per-pid deltas; a failure just
/// leaves rates at 0.
private final class NettopRates {

    private struct Counter {
        var bytes: UInt64
        var timestamp: TimeInterval
    }

    private let interval: TimeInterval = 2.0
    private let queue = DispatchQueue(label: "TaskManager.nettop", qos: .utility)
    private let lock = NSLock()
    private var rates: [pid_t: Double] = [:]
    private var counters: [pid_t: Counter] = [:]
    private var lastRun: TimeInterval = -.greatestFiniteMagnitude
    private var running = false

    func snapshot() -> [pid_t: Double] {
        lock.lock()
        defer { lock.unlock() }
        return rates
    }

    func refreshIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let due = !running && now - lastRun >= interval
        if due {
            running = true
            lastRun = now
        }
        lock.unlock()
        guard due else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let totals = Self.readTotals()
            self.apply(totals)
            self.lock.lock()
            self.running = false
            self.lock.unlock()
        }
    }

    private func apply(_ totals: [pid_t: UInt64]) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }

        guard !totals.isEmpty else {
            rates.removeAll(keepingCapacity: true)
            counters.removeAll(keepingCapacity: true)
            return
        }

        var updated: [pid_t: Double] = [:]
        updated.reserveCapacity(totals.count)
        for (pid, bytes) in totals {
            if let prev = counters[pid], bytes > prev.bytes {
                let elapsed = now - prev.timestamp
                if elapsed > 0.01 {
                    updated[pid] = Double(bytes - prev.bytes) / elapsed
                }
            }
            counters[pid] = Counter(bytes: bytes, timestamp: now)
        }
        counters = counters.filter { totals[$0.key] != nil }
        rates = updated
    }

    /// `nettop -P -L 1 -x -J bytes_in,bytes_out` prints CSV rows of
    /// "<name>.<pid>,<bytes_in>,<bytes_out>," with a header row first.
    ///
    /// The identifier column is located by shape rather than by a fixed index:
    /// nettop prepends a time column under some flag combinations, and a silent
    /// off-by-one here would read as "no network activity" forever.
    private static func readTotals() -> [pid_t: UInt64] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]   // nettop missing or blocked: rates stay 0.
        }

        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var totals: [pid_t: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let column = fields.firstIndex(where: { pid(from: $0) != nil }),
                  let pid = pid(from: fields[column]),
                  fields.count > column + 2,
                  let inBytes = UInt64(fields[column + 1].trimmingCharacters(in: .whitespaces)),
                  let outBytes = UInt64(fields[column + 2].trimmingCharacters(in: .whitespaces))
            else { continue }
            // A process with several interfaces gets one row per interface.
            totals[pid, default: 0] += inBytes &+ outBytes
        }
        return totals
    }

    /// "Google Chrome.1234" -> 1234. Names legitimately contain dots, so the pid
    /// is taken from the last component only.
    private static func pid(from field: Substring) -> pid_t? {
        guard let dot = field.lastIndex(of: "."), dot > field.startIndex else { return nil }
        let tail = field[field.index(after: dot)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return nil }
        return pid_t(tail)
    }
}

// MARK: - Power usage trend

/// Rolling per-pid CPU average, exponentially smoothed. Kept separate from
/// ProcRow (an immutable per-tick snapshot) so the "Power usage trend" column
/// can genuinely lag "Power usage" instead of mirroring it.
final class ProcessPowerTrend {
    static let shared = ProcessPowerTrend()

    private let lock = NSLock()
    private var averages: [pid_t: Double] = [:]

    /// Settles over roughly 10 samples, visibly slower to react than the
    /// instantaneous reading.
    private let smoothing = 0.1

    func value(for pid: pid_t) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return averages[pid] ?? 0
    }

    func update(pid: pid_t, cpuPercent: Double) {
        lock.lock()
        defer { lock.unlock() }
        let previous = averages[pid] ?? cpuPercent
        averages[pid] = previous + smoothing * (cpuPercent - previous)
    }

    func prune(live: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        if averages.count != live.count {
            averages = averages.filter { live.contains($0.key) }
        }
    }
}
