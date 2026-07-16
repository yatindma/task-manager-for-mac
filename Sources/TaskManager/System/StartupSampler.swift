import AppKit
import Foundation

/// The Startup apps tab.
///
/// Two honest sources exist on macOS: the login-item list (what System Settings
/// calls "Open at Login", covering both SMAppService registrations and the
/// legacy list) and LaunchAgents with `RunAtLoad`. Windows' "Startup impact"
/// has no macOS equivalent — launchd does not time agents — so it reads
/// "Not measured" for every row rather than inventing a number.
final class StartupSampler {

    private static let agentDirectories = [
        NSHomeDirectory() + "/Library/LaunchAgents",
        "/Library/LaunchAgents",
    ]

    /// Bundle identifiers are read from disk, which is stable for a given path.
    private var publisherCache: [String: String] = [:]

    init() {}

    func sample() -> [StartupRow] {
        let disabled = disabledLabels()
        var rows: [String: StartupRow] = [:]

        for item in loginItems() {
            rows[item.path] = StartupRow(
                name: item.name,
                publisher: publisher(forPath: item.path),
                status: "Enabled",  // System Events only lists items that are registered to run.
                impact: "Not measured",
                path: item.path,
                isLoginItem: true
            )
        }

        for agent in launchAgents() {
            guard rows[agent.plistPath] == nil else { continue }
            let isDisabled = agent.disabledInPlist || disabled.contains(agent.label)
            rows[agent.plistPath] = StartupRow(
                name: agent.name,
                publisher: publisher(forPath: agent.program ?? agent.plistPath),
                status: isDisabled ? "Disabled" : "Enabled",
                impact: "Not measured",
                path: agent.plistPath,
                isLoginItem: false
            )
        }

        return rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Login items

    private struct LoginItem {
        var name: String
        var path: String
    }

    private func loginItems() -> [LoginItem] {
        // System Events is the only documented way to read the login-item list;
        // it returns nothing (rather than failing) if automation is not permitted.
        let script = """
        tell application "System Events"
            set out to ""
            repeat with i in login items
                set out to out & (name of i) & "\t" & (path of i) & "\n"
            end repeat
            return out
        end tell
        """
        guard let output = Shell.run("/usr/bin/osascript", ["-e", script]) else { return [] }

        var items: [LoginItem] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let path = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            items.append(LoginItem(name: String(fields[0]), path: path))
        }
        return items
    }

    // MARK: - LaunchAgents

    private struct Agent {
        var label: String
        var name: String
        var plistPath: String
        var program: String?
        var disabledInPlist: Bool
    }

    private func launchAgents() -> [Agent] {
        var agents: [Agent] = []
        for dir in Self.agentDirectories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in names where file.hasSuffix(".plist") {
                let full = dir + "/" + file
                guard let dict = NSDictionary(contentsOfFile: full),
                      dict["RunAtLoad"] as? Bool == true
                else { continue }

                let label = (dict["Label"] as? String) ?? String(file.dropLast(6))
                var program = dict["Program"] as? String
                if program == nil, let args = dict["ProgramArguments"] as? [String] {
                    program = args.first
                }

                agents.append(Agent(
                    label: label,
                    name: Self.agentName(label: label, program: program),
                    plistPath: full,
                    program: program,
                    disabledInPlist: dict["Disabled"] as? Bool == true
                ))
            }
        }
        return agents
    }

    /// Labels launchd has overridden to disabled, which outranks the plist's own key.
    private func disabledLabels() -> Set<String> {
        guard let output = Shell.run("/bin/launchctl", ["print-disabled", "user/\(getuid())"]) else {
            return []
        }

        var labels: Set<String> = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("=> disabled"),
                  let start = trimmed.firstIndex(of: "\""),
                  let end = trimmed[trimmed.index(after: start)...].firstIndex(of: "\"")
            else { continue }
            labels.insert(String(trimmed[trimmed.index(after: start)..<end]))
        }
        return labels
    }

    private static func agentName(label: String, program: String?) -> String {
        if let program, !program.isEmpty {
            let base = (program as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return label
    }

    // MARK: - Publisher

    /// The owning bundle's identifier, read from its Info.plist — no per-item
    /// `codesign` fork. Falls back to an em-dash when the path is a bare tool.
    private func publisher(forPath path: String) -> String {
        if let cached = publisherCache[path] { return cached }

        var result = "—"
        if let bundlePath = Self.enclosingBundlePath(path),
           let bundle = Bundle(path: bundlePath) {
            if let identifier = bundle.bundleIdentifier {
                result = identifier
            } else if let name = bundle.infoDictionary?["CFBundleName"] as? String {
                result = name
            }
        }

        publisherCache[path] = result
        return result
    }

    /// The nearest enclosing `.app` for an executable inside one, or the path itself.
    private static func enclosingBundlePath(_ path: String) -> String? {
        if path.hasSuffix(".app") || path.hasSuffix(".app/") { return path }

        var current = (path as NSString).standardizingPath
        while current != "/" && !current.isEmpty {
            if current.hasSuffix(".app") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}
