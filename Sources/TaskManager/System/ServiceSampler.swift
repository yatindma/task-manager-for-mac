import Foundation

/// launchd is the macOS analogue of Windows services.
///
/// `launchctl list` reports the caller's domain (per-user agents plus the
/// system daemons visible to it). System daemons that launchd will not disclose
/// to an unprivileged caller are still listed, sourced from their plists, with
/// no PID — Windows would show them as "Stopped", and so do we.
final class ServiceSampler {

    /// Directories searched for a label's plist, in launchd's own precedence order.
    private static let plistDirectories: [(path: String, isSystem: Bool)] = [
        (NSHomeDirectory() + "/Library/LaunchAgents", false),
        ("/Library/LaunchAgents", false),
        ("/Library/LaunchDaemons", true),
        ("/System/Library/LaunchAgents", false),
        ("/System/Library/LaunchDaemons", true),
    ]

    private struct PlistEntry {
        var path: String
        var isSystem: Bool
        var programName: String?
    }

    /// label -> plist. Scanning ~4000 plists takes seconds, so it is cached and
    /// only rebuilt when one of the directories changes on disk.
    private var plistIndex: [String: PlistEntry] = [:]
    private var indexStamps: [String: Date] = [:]

    init() {}

    func sample() -> [ServiceRow] {
        refreshIndexIfNeeded()

        var rows: [String: ServiceRow] = [:]

        for entry in launchctlList() {
            let plist = plistIndex[entry.label]
            rows[entry.label] = ServiceRow(
                label: entry.label,
                pid: entry.pid,
                displayName: Self.displayName(label: entry.label, program: plist?.programName),
                status: entry.pid == nil ? "Stopped" : "Running",
                lastExitCode: entry.lastExitCode,
                isSystem: plist?.isSystem ?? entry.label.hasPrefix("com.apple."),
                plistPath: plist?.path ?? ""
            )
        }

        // Daemons we know from disk but that launchctl did not report to us.
        for (label, entry) in plistIndex where rows[label] == nil {
            rows[label] = ServiceRow(
                label: label,
                pid: nil,
                displayName: Self.displayName(label: label, program: entry.programName),
                status: "Stopped",
                lastExitCode: 0,
                isSystem: entry.isSystem,
                plistPath: entry.path
            )
        }

        return rows.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - launchctl

    private struct ListEntry {
        var pid: pid_t?
        var lastExitCode: Int
        var label: String
    }

    private func launchctlList() -> [ListEntry] {
        guard let output = Shell.run("/bin/launchctl", ["list"]) else { return [] }

        var entries: [ListEntry] = []
        for line in output.split(separator: "\n").dropFirst() {  // drop "PID Status Label"
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }

            let label = String(fields[2])
            guard !label.isEmpty else { continue }

            entries.append(ListEntry(
                pid: pid_t(fields[0]),                  // "-" when not running
                lastExitCode: Int(fields[1]) ?? 0,      // "-" when never run
                label: label
            ))
        }
        return entries
    }

    // MARK: - Plist index

    private func refreshIndexIfNeeded() {
        var stamps: [String: Date] = [:]
        for dir in Self.plistDirectories {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
            if let modified = attrs?[.modificationDate] as? Date {
                stamps[dir.path] = modified
            }
        }
        guard stamps != indexStamps || plistIndex.isEmpty else { return }
        indexStamps = stamps

        var index: [String: PlistEntry] = [:]
        for dir in Self.plistDirectories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".plist") {
                let full = dir.path + "/" + name
                guard let dict = NSDictionary(contentsOfFile: full) else { continue }

                let label = (dict["Label"] as? String) ?? String(name.dropLast(6))
                var program = dict["Program"] as? String
                if program == nil, let args = dict["ProgramArguments"] as? [String] {
                    program = args.first
                }

                // Earlier directories win, matching launchd's precedence.
                if index[label] == nil {
                    index[label] = PlistEntry(
                        path: full,
                        isSystem: dir.isSystem,
                        programName: program.map { ($0 as NSString).lastPathComponent }
                    )
                }
            }
        }
        plistIndex = index
    }

    // MARK: - Naming

    /// "com.apple.SafariHistoryServiceAgent" -> "Safari History Service Agent".
    private static func displayName(label: String, program: String?) -> String {
        var stem = label.split(separator: ".").last.map(String.init) ?? label
        if stem.isEmpty || Int(stem) != nil, let program, !program.isEmpty {
            stem = program
        }
        let words = prettify(stem)
        return words.isEmpty ? label : words
    }

    private static func prettify(_ raw: String) -> String {
        let separated = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        var out = ""
        var previous: Character?
        for ch in separated {
            if let previous, ch.isUppercase, !previous.isUppercase, !previous.isWhitespace {
                out.append(" ")
            }
            out.append(ch)
            previous = ch
        }

        let words = out.split(separator: " ").map { word -> String in
            guard let first = word.first, first.isLowercase else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Shell

/// Minimal wrapper for the /bin, /usr/bin, /usr/sbin tools the samplers rely on.
enum Shell {
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 15) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning { process.terminate() }

        return String(data: data, encoding: .utf8)
    }
}
