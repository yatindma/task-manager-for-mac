import AppKit
import Darwin
import Foundation

/// Stats the helper can read for every pid, including ones we do not own.
struct PrivStats {
    var cpuNanos: UInt64
    var threads: Int
    var footprint: UInt64
    var diskRead: UInt64
    var diskWrite: UInt64
    var fds: Int
}

/// Client for the setuid-root helper.
///
/// Without it, `proc_pidinfo` returns nothing for root-owned processes — on a typical
/// Mac that hides ~120 of ~620 processes, including WindowServer and kernel_task. The
/// app works fine without it and simply reports those as idle; installing it is a
/// one-time, user-initiated upgrade that survives reboots because the setuid bit lives
/// on disk.
final class PrivilegedHelper: ObservableObject, @unchecked Sendable {
    static let shared = PrivilegedHelper()

    /// Matches `helperVersion` in tmhelper. A bump forces a reinstall.
    private static let expectedVersion = 1
    private static let installPath = "/Library/Application Support/TaskManager/tmhelper"

    /// True once a helper of the expected version answered a PING.
    @Published private(set) var isAvailable = false
    /// Set when the user dismisses the banner; we stop offering until next launch.
    @Published var isDismissed = false

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()

    private init() {
        connect()
    }

    // MARK: - Connection

    /// Spawns the installed helper and verifies it answers with the version we expect.
    private func connect() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()

        guard FileManager.default.isExecutableFile(atPath: Self.installPath) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.installPath)
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return
        }

        process = proc
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading

        guard let reply = sendLocked("PING"),
              reply.hasPrefix("PONG "),
              Int(reply.dropFirst(5).trimmingCharacters(in: .whitespaces)) == Self.expectedVersion
        else {
            teardownLocked()
            return
        }

        publish(available: true)
    }

    private func teardownLocked() {
        if process?.isRunning == true {
            try? input?.write(contentsOf: Data("QUIT\n".utf8))
            process?.terminate()
        }
        process = nil
        input = nil
        output = nil
        readBuffer.removeAll(keepingCapacity: false)
        publish(available: false)
    }

    private func publish(available: Bool) {
        if Thread.isMainThread {
            isAvailable = available
        } else {
            DispatchQueue.main.async { self.isAvailable = available }
        }
    }

    // MARK: - Transport

    /// Writes one command and reads until `terminator`. Caller must hold `lock`.
    private func sendLocked(_ command: String, until terminator: String = "\n") -> String? {
        guard let input, let output else { return nil }

        do {
            try input.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            teardownLocked()
            return nil
        }

        while true {
            if let range = readBuffer.range(of: Data(terminator.utf8)) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<range.lowerBound)
                readBuffer.removeSubrange(readBuffer.startIndex..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            guard let chunk = try? output.read(upToCount: 1 << 16), !chunk.isEmpty else {
                // Helper died mid-conversation — drop the connection so the next call retries.
                teardownLocked()
                return nil
            }
            readBuffer.append(chunk)
        }
    }

    // MARK: - Queries

    /// All-process stats, or nil when the helper is unavailable — callers then fall
    /// back to sampling only the processes they own.
    func sample() -> [pid_t: PrivStats]? {
        lock.lock()
        defer { lock.unlock() }
        guard process != nil else { return nil }
        guard let body = sendLocked("SAMPLE", until: "END\n") else { return nil }

        var result = [pid_t: PrivStats](minimumCapacity: 700)
        for line in body.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 7, let pid = pid_t(f[0]) else { continue }
            result[pid] = PrivStats(
                cpuNanos: UInt64(f[1]) ?? 0,
                threads: Int(f[2]) ?? 0,
                footprint: UInt64(f[3]) ?? 0,
                diskRead: UInt64(f[4]) ?? 0,
                diskWrite: UInt64(f[5]) ?? 0,
                fds: Int(f[6]) ?? 0
            )
        }
        return result
    }

    /// Signals a pid as root. `signal` must be one of TERM/KILL/STOP/CONT.
    func kill(_ pid: pid_t, _ signal: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard process != nil else { return false }
        return sendLocked("KILL \(pid) \(signal)") == "OK"
    }

    // MARK: - Install

    enum InstallError: LocalizedError {
        case helperMissingFromBundle
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissingFromBundle:
                return "The helper is missing from the app bundle. Rebuild with build.sh."
            case .cancelled:
                return "Authorisation was cancelled."
            case .failed(let message):
                return message
            }
        }
    }

    /// Copies the bundled helper into place and marks it setuid-root, behind one
    /// native authorisation prompt. Runs once per machine — the installed bit persists
    /// across reboots and app updates.
    func install() throws {
        guard let source = Bundle.main.url(forResource: "tmhelper", withExtension: nil)?.path,
              FileManager.default.isExecutableFile(atPath: source)
        else { throw InstallError.helperMissingFromBundle }

        let dir = (Self.installPath as NSString).deletingLastPathComponent
        let script = """
        /bin/mkdir -p \(shellQuoted(dir)) && \
        /bin/cp -f \(shellQuoted(source)) \(shellQuoted(Self.installPath)) && \
        /usr/sbin/chown root:wheel \(shellQuoted(Self.installPath)) && \
        /bin/chmod 4755 \(shellQuoted(Self.installPath))
        """

        var error: NSDictionary?
        let source_ = "do shell script \(appleScriptQuoted(script)) with administrator privileges"
        guard let apple = NSAppleScript(source: source_) else {
            throw InstallError.failed("Could not build the install script.")
        }
        apple.executeAndReturnError(&error)

        if let error {
            // -128 is the standard "user cancelled" code from the auth prompt.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw InstallError.cancelled }
            let message = error[NSAppleScript.errorMessage] as? String ?? "Install failed."
            throw InstallError.failed(message)
        }

        connect()
        guard isAvailable else {
            throw InstallError.failed("The helper installed but did not respond. Try again.")
        }
    }

    /// Wraps a path for /bin/sh single-quoting.
    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wraps a shell command as an AppleScript string literal.
    private func appleScriptQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
