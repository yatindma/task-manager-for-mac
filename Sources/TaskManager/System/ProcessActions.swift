import AppKit
import Darwin
import Foundation

/// Failures surfaced by the "Run new task" dialog.
enum ProcessActionError: LocalizedError {
    case emptyCommand
    case launchFailed(String, underlying: String)
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Enter the name of a program, folder, document, or command to open."
        case let .launchFailed(command, underlying):
            return "Could not run “\(command)”. \(underlying)"
        case let .authorizationFailed(reason):
            return "Could not run the task as an administrator. \(reason)"
        }
    }
}

/// The actions behind the Processes tab's context menu and command bar.
///
/// Signals against processes owned by another user or by the system fail with
/// EPERM. That is normal and expected without root, so these return `false`
/// rather than trapping.
enum ProcessActions {

    // MARK: - Signals

    static func endTask(_ pid: pid_t) -> Bool {
        signal(pid, SIGTERM)
    }

    static func forceKill(_ pid: pid_t) -> Bool {
        signal(pid, SIGKILL)
    }

    /// Terminates every descendant before the parent, so children are not
    /// reparented to launchd and left running.
    static func endTree(_ pid: pid_t) -> Bool {
        var ok = true
        for child in descendants(of: pid).reversed() {
            if !signal(child, SIGTERM) { ok = false }
        }
        if !signal(pid, SIGTERM) { ok = false }
        return ok
    }

    static func suspend(_ pid: pid_t) -> Bool {
        signal(pid, SIGSTOP)
    }

    static func resume(_ pid: pid_t) -> Bool {
        signal(pid, SIGCONT)
    }

    private static func signal(_ pid: pid_t, _ sig: Int32) -> Bool {
        // Guard against 0 and negatives: kill() reads those as "signal my whole
        // process group", which would take this app down with the target.
        guard pid > 0 else { return false }
        return kill(pid, sig) == 0
    }

    // MARK: - Reveal

    /// Windows' "Search online" context item. Bing is not a preference — it is what
    /// the Task Manager this clones actually opens.
    static func searchOnline(_ terms: String...) {
        var components = URLComponents(string: "https://www.bing.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: terms.joined(separator: " "))]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Run new task

    static func runNewTask(command: String, asAdmin: Bool) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProcessActionError.emptyCommand }

        if asAdmin {
            try runAsAdministrator(trimmed)
        } else if let url = bundleOrFileURL(for: trimmed) {
            try open(url, command: trimmed)
        } else {
            try runInShell(trimmed)
        }
    }

    /// A bare path to an .app, a document, or a folder is opened by Launch
    /// Services; anything else is treated as a shell command line.
    private static func bundleOrFileURL(for command: String) -> URL? {
        guard command.hasPrefix("/") || command.hasPrefix("~") else { return nil }
        let path = (command as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: path)
        // A plain executable must run in a shell, not be handed to Finder.
        if !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path) {
            return nil
        }
        return url
    }

    private static func open(_ url: URL, command: String) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // openApplication/open are async; bridge the first result back so a bad
        // launch surfaces as a thrown error rather than silence.
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        let isApp = url.pathExtension == "app"

        if isApp {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                failure = error
                semaphore.signal()
            }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                failure = error
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut { return }
        if let failure {
            throw ProcessActionError.launchFailed(command, underlying: failure.localizedDescription)
        }
    }

    private static func runInShell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // Detached: the task outlives Task Manager, as it does on Windows.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessActionError.launchFailed(command, underlying: error.localizedDescription)
        }
    }

    /// AppleScript's `with administrator privileges` gives the native macOS
    /// authorisation prompt — the closest thing to Windows' "as administrator".
    private static func runAsAdministrator(_ command: String) throws {
        let source = """
        do shell script \(appleScriptString(command)) with administrator privileges
        """
        guard let script = NSAppleScript(source: source) else {
            throw ProcessActionError.authorizationFailed("The command could not be prepared.")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }

        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Authorisation was cancelled."
        throw ProcessActionError.authorizationFailed(message)
    }

    /// AppleScript string literals only escape backslash and double quote.
    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Process tree

    /// Descendants of `pid`, parents before children, from a fresh snapshot so
    /// the walk never races the sampler's cached tree.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        var childrenOf: [pid_t: [pid_t]] = [:]
        for kp in snapshot() {
            let child = kp.kp_proc.p_pid
            let parent = kp.kp_eproc.e_ppid
            guard child > 0, parent != child else { continue }
            childrenOf[parent, default: []].append(child)
        }

        var result: [pid_t] = []
        var queue: [pid_t] = [pid]
        var seen: Set<pid_t> = [pid]
        while let current = queue.first {
            queue.removeFirst()
            for child in childrenOf[current] ?? [] where seen.insert(child).inserted {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private static func snapshot() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = (size + size / 8) / MemoryLayout<kinfo_proc>.stride + 1
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var read = count * MemoryLayout<kinfo_proc>.stride
        let ok = buffer.withUnsafeMutableBufferPointer { buf -> Bool in
            sysctl(&mib, 4, buf.baseAddress, &read, nil, 0) == 0
        }
        guard ok else { return [] }
        return Array(buffer.prefix(read / MemoryLayout<kinfo_proc>.stride))
    }
}
