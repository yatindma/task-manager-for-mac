import Darwin
import Foundation
import SystemConfiguration

/// The Users tab.
///
/// Sessions come from utmpx, the same database `who` reads. Resource totals are
/// aggregated from the process list, which is why `sample` takes it as input.
final class UserSampler {

    /// pw_gecos does not change while the app runs.
    private var fullNameCache: [String: String] = [:]

    init() {}

    func sample(processes: [ProcRow]) -> [UserRow] {
        let sessions = utmpxSessions()
        let console = consoleUsername()

        var totals: [String: (cpu: Double, memory: UInt64, rows: [ProcRow])] = [:]
        for proc in Self.flatten(processes) {
            var entry = totals[proc.user] ?? (0, 0, [])
            entry.cpu += proc.cpu
            entry.memory += proc.memoryBytes
            entry.rows.append(proc)
            totals[proc.user] = entry
        }

        // One row per user: keep the earliest login, prefer a console session's kind.
        var rows: [String: UserRow] = [:]
        for session in sessions {
            let total = totals[session.username] ?? (0, 0, [])

            if var existing = rows[session.username] {
                if session.loginTime < existing.loginTime { existing.loginTime = session.loginTime }
                if session.kind == "Console" { existing.sessionKind = "Console" }
                rows[session.username] = existing
                continue
            }

            rows[session.username] = UserRow(
                username: session.username,
                fullName: fullName(for: session.username),
                status: session.username == console ? "Active" : "Disconnected",
                sessionKind: session.kind,
                loginTime: session.loginTime,
                cpu: total.cpu,
                memoryBytes: total.memory,
                processes: total.rows
            )
        }

        // utmpx can be empty in a sandboxed or headless launch; the console user
        // is still a real session, so synthesise it rather than showing nothing.
        if rows.isEmpty, let console {
            let total = totals[console] ?? (0, 0, [])
            rows[console] = UserRow(
                username: console,
                fullName: fullName(for: console),
                status: "Active",
                sessionKind: "Console",
                loginTime: Self.bootTime(),
                cpu: total.cpu,
                memoryBytes: total.memory,
                processes: total.rows
            )
        }

        return rows.values.sorted { $0.loginTime < $1.loginTime }
    }

    // MARK: - utmpx

    private struct Session {
        var username: String
        var kind: String
        var loginTime: Date
    }

    private func utmpxSessions() -> [Session] {
        var sessions: [Session] = []

        setutxent()
        defer { endutxent() }

        while let pointer = getutxent() {
            let entry = pointer.pointee
            guard Int32(entry.ut_type) == USER_PROCESS else { continue }

            let username = Self.cString(entry.ut_user)
            guard !username.isEmpty else { continue }

            let host = Self.cString(entry.ut_host)
            let line = Self.cString(entry.ut_line)

            let kind: String
            if !host.isEmpty {
                kind = "SSH"
            } else if line == "console" {
                kind = "Console"
            } else {
                kind = "Terminal"
            }

            let seconds = Double(entry.ut_tv.tv_sec) + Double(entry.ut_tv.tv_usec) / 1_000_000
            sessions.append(Session(
                username: username,
                kind: kind,
                loginTime: Date(timeIntervalSince1970: seconds)
            ))
        }

        return sessions
    }

    // MARK: - Identity

    private func fullName(for username: String) -> String {
        if let cached = fullNameCache[username] { return cached }

        var result = username
        if let entry = getpwnam(username), let gecos = entry.pointee.pw_gecos {
            // pw_gecos is comma-separated; the first field is the display name.
            let full = String(cString: gecos)
            let name = full.split(separator: ",").first.map(String.init) ?? full
            if !name.isEmpty { result = name }
        }

        fullNameCache[username] = result
        return result
    }

    private func consoleUsername() -> String? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, !name.isEmpty {
            return name
        }
        return NSUserName()
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

    private static func bootTime() -> Date {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: Double(boot.tv_sec))
    }

    /// Reads a fixed-size C char array (imported into Swift as a tuple) as a String.
    private static func cString<T>(_ tuple: T) -> String {
        withUnsafePointer(to: tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { chars in
                var buffer: [CChar] = []
                for index in 0..<MemoryLayout<T>.size {
                    let byte = chars[index]
                    if byte == 0 { break }
                    buffer.append(byte)
                }
                buffer.append(0)
                return String(cString: buffer)
            }
        }
    }
}
