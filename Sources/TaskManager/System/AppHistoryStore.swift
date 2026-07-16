import AppKit
import Foundation
import Network

/// Accumulates per-app resource usage the way Windows' App history tab does.
///
/// Windows reads this out of its own long-running metering service; macOS keeps
/// no such ledger, so we integrate the live samples ourselves and persist them.
///
/// `meteredNetworkBytes` tracks bytes attributed while `NWPathMonitor` reports the
/// active path as expensive (cellular/hotspot) or constrained (Low Data Mode) — the
/// documented public notion of a metered connection on macOS. It is a subset of
/// `networkBytes`, not a separately measured quantity, since macOS has no per-app
/// metered accounting API.
final class AppHistoryStore {

    private struct Entry: Codable {
        var bundleID: String
        var name: String
        var cpuTimeSeconds: Double
        var networkBytes: UInt64
        var meteredNetworkBytes: UInt64
    }

    private struct Identity {
        var bundleID: String
        var name: String
    }

    private static let writeInterval: TimeInterval = 30
    /// A tick this long apart means the app was asleep or paused; integrating
    /// across it would invent usage that never happened.
    private static let maxTickInterval: TimeInterval = 10

    /// ProcRow.cpu is normalised 0...100 across every core (matching the Windows
    /// Processes tab), so recovering true CPU-seconds requires scaling back up
    /// by the machine's own core count.
    private let activeCPUs = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))

    private var entries: [String: Entry] = [:]
    private var identityCache: [String: Identity] = [:]
    private var iconCache: [String: NSImage?] = [:]

    private var lastRecord: Date?
    private var lastWrite: Date = .distantPast

    private let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TaskManager/app-history.json")
    }()

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "TaskManager.AppHistoryStore.path")
    private let meteredLock = NSLock()
    private var meteredLocked = false

    private var isMetered: Bool {
        meteredLock.lock()
        defer { meteredLock.unlock() }
        return meteredLocked
    }

    init() {
        load()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let metered = path.isExpensive || path.isConstrained
            self.meteredLock.lock()
            self.meteredLocked = metered
            self.meteredLock.unlock()
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Recording

    func record(_ procs: [ProcRow]) {
        let now = Date()
        defer { lastRecord = now }

        guard let previous = lastRecord else { return }  // first tick establishes the baseline
        let elapsed = now.timeIntervalSince(previous)
        guard elapsed > 0, elapsed <= Self.maxTickInterval else { return }

        for proc in Self.flatten(procs) {
            let identity = identity(for: proc)

            var entry = entries[identity.bundleID]
                ?? Entry(bundleID: identity.bundleID, name: identity.name,
                         cpuTimeSeconds: 0, networkBytes: 0, meteredNetworkBytes: 0)

            entry.cpuTimeSeconds += proc.cpu / 100 * activeCPUs * elapsed
            entry.networkBytes += UInt64(max(proc.networkRate, 0) * elapsed)
            if isMetered {
                entry.meteredNetworkBytes += UInt64(max(proc.networkRate, 0) * elapsed)
            }
            entry.name = identity.name
            entries[identity.bundleID] = entry
        }

        if now.timeIntervalSince(lastWrite) >= Self.writeInterval {
            lastWrite = now
            save()
        }
    }

    func rows() -> [AppHistoryRow] {
        entries.values
            .sorted { $0.cpuTimeSeconds > $1.cpuTimeSeconds }
            .map { entry in
                AppHistoryRow(
                    bundleID: entry.bundleID,
                    name: entry.name,
                    cpuTimeSeconds: entry.cpuTimeSeconds,
                    networkBytes: entry.networkBytes,
                    meteredNetworkBytes: entry.meteredNetworkBytes,
                    icon: icon(for: entry.bundleID)
                )
            }
    }

    // MARK: - Identity

    private func identity(for proc: ProcRow) -> Identity {
        let key = proc.path.isEmpty ? proc.name : proc.path
        if let cached = identityCache[key] { return cached }

        var resolved = Identity(bundleID: proc.name, name: proc.displayName)
        if let bundlePath = Self.enclosingBundlePath(proc.path),
           let bundle = Bundle(path: bundlePath),
           let identifier = bundle.bundleIdentifier {
            let displayName = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? proc.displayName
            resolved = Identity(bundleID: identifier, name: displayName)
        }

        identityCache[key] = resolved
        return resolved
    }

    private static func enclosingBundlePath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var current = (path as NSString).standardizingPath
        while current != "/" && !current.isEmpty {
            if current.hasSuffix(".app") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }

        var image: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }

        iconCache[bundleID] = image
        return image
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = Dictionary(decoded.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func save() {
        let directory = storeURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(entries.values))
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // History is best-effort: a failed write must never disturb sampling.
        }
    }

    // MARK: - Helpers

    private static func flatten(_ rows: [ProcRow]) -> [ProcRow] {
        var out: [ProcRow] = []
        for row in rows {
            out.append(row)
            out.append(contentsOf: flatten(row.children))
        }
        return out
    }
}
