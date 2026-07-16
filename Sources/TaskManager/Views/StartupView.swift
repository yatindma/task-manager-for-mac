import AppKit
import SwiftUI

/// The Startup apps tab: login items and RunAtLoad LaunchAgents, with
/// enable/disable routed through launchctl or System Events.
struct StartupView: View {
    init() {}

    private enum Column: String, CaseIterable {
        case name = "Name"
        case publisher = "Publisher"
        case status = "Status"
        case impact = "Startup impact"

        var width: CGFloat? {
            switch self {
            case .name: return nil
            case .publisher: return 180
            case .status: return 96
            case .impact: return 120
            }
        }
    }

    @ObservedObject private var monitor = SystemMonitor.shared
    @StateObject private var columnState = TableColumnState(tableID: "startup")
    @ObservedObject private var selectionBridge = TabSelectionBridge.shared
    @Environment(\.colorScheme) private var scheme

    @State private var sortColumn: Column = .name
    @State private var direction: SortDirection = .ascending

    var body: some View {
        let rows = sorted(monitor.startupItems)

        VStack(spacing: 0) {
            blurb

            TableScroller(minimumWidth: columnState.minimumWidth(of: columnSpecs)) {
                VStack(spacing: 0) {
                    TableHeaderView(
                        columns: columnSpecs,
                        sortColumnID: sortColumn.rawValue,
                        direction: direction,
                        onSort: sort(by:),
                        state: columnState
                    )

                    if rows.isEmpty {
                        emptyState
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { row in
                                    StartupRowView(
                                        row: row,
                                        columns: columnSpecs,
                                        isSelected: selectionBridge.selectedStartupID == row.id,
                                        state: columnState
                                    )
                                    .onTapGesture { selectionBridge.selectedStartupID = row.id }
                                    .contextMenu { menu(for: row) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(WinTheme.Palette.card(scheme))
        .onReceive(NotificationCenter.default.publisher(for: .primaryCommandInvoked)) { note in
            guard note.object as? Tab == .startupApps,
                  let id = selectionBridge.selectedStartupID,
                  let row = rows.first(where: { $0.id == id })
            else { return }
            setEnabled(row.status != "Enabled", row)
        }
    }

    private var emptyState: some View {
        VStack {
            Text("No startup apps found. If you expect items here, grant Task Manager automation access for System Events in System Settings › Privacy & Security › Automation.")
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Header blurb

    /// Windows prints "Last BIOS time" here. macOS has no BIOS and exposes no
    /// firmware-handoff duration, so the closest honest figure is the moment the
    /// kernel booted, derived from CPUStats.uptime.
    private var blurb: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Apps and agents that start automatically when you sign in.")
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Text("Last boot time:")
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                Text(bootTimeText)
                    .font(WinTheme.Typography.rowEmphasis)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
            }
            .help("macOS reports no BIOS hand-off time; this is when the kernel booted.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var bootTimeText: String {
        let uptime = monitor.cpu.uptime
        guard uptime > 0 else { return "—" }
        return Self.bootFormatter.string(from: Date().addingTimeInterval(-uptime))
    }

    private static let bootFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Columns

    private var columnSpecs: [TableColumnSpec] {
        Column.allCases.map { column in
            TableColumnSpec(
                id: column.rawValue,
                title: column.rawValue,
                defaultWidth: column.width,
                alignment: .leading,
                canHide: column != .name
            )
        }
    }

    private func sort(by id: String) {
        guard let column = Column(rawValue: id) else { return }
        if column == sortColumn {
            direction = direction.flipped
        } else {
            sortColumn = column
            direction = .ascending
        }
    }

    private func sorted(_ rows: [StartupRow]) -> [StartupRow] {
        let ascending = direction == .ascending
        return rows.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .name: result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .publisher: result = a.publisher.localizedCaseInsensitiveCompare(b.publisher) == .orderedAscending
            case .status: result = a.status.localizedCaseInsensitiveCompare(b.status) == .orderedAscending
            case .impact: result = a.impact.localizedCaseInsensitiveCompare(b.impact) == .orderedAscending
            }
            return ascending ? result : !result
        }
    }

    // MARK: - Commands

    @ViewBuilder
    private func menu(for row: StartupRow) -> some View {
        Button("Enable") { setEnabled(true, row) }
            .disabled(row.status == "Enabled")
        Button("Disable") { setEnabled(false, row) }
            .disabled(row.status == "Disabled")

        Divider()

        Button("Open file location") { ProcessActions.revealInFinder(row.path) }
        Button("Search online") { ProcessActions.searchOnline(row.name, (row.path as NSString).lastPathComponent) }
        Button("Properties") { showProperties(row) }
    }

    private func setEnabled(_ enabled: Bool, _ row: StartupRow) {
        do {
            if row.isLoginItem {
                try StartupControl.setLoginItem(enabled: enabled, name: row.name, path: row.path)
            } else {
                try StartupControl.setLaunchAgent(enabled: enabled, plistPath: row.path)
            }
            monitor.refreshNow()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = enabled
                ? "Couldn't enable \(row.name)."
                : "Couldn't disable \(row.name)."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Windows opens the shell Properties sheet; the Finder Info window is the
    /// direct macOS counterpart.
    private func showProperties(_ row: StartupRow) {
        let escaped = row.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        _ = Shell.run("/usr/bin/osascript", ["-e", script])
    }
}

// MARK: - Enable / disable

enum StartupControl {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// LaunchAgents live in the per-user GUI domain. Agents inside the user's
    /// home need no authorisation; the ones installed under /Library do.
    static func setLaunchAgent(enabled: Bool, plistPath: String) throws {
        guard let label = label(forPlist: plistPath) else {
            throw Failure(message: "The agent's plist at \(plistPath) has no Label key.")
        }

        let target = "gui/\(getuid())/\(label)"
        let verb = enabled ? "enable" : "disable"
        let needsAdmin = !plistPath.hasPrefix(NSHomeDirectory())

        try ProcessActions.runNewTask(
            command: "/bin/launchctl \(verb) \(target)",
            asAdmin: needsAdmin
        )
    }

    /// System Events exposes no enabled flag on login items, so Windows'
    /// Enable/Disable maps onto adding and removing the item.
    static func setLoginItem(enabled: Bool, name: String, path: String) throws {
        let script: String
        if enabled {
            script = """
            tell application "System Events"
                make new login item at end with properties ¬
                    {path:"\(escape(path))", name:"\(escape(name))", hidden:false}
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                delete (every login item whose path is "\(escape(path))")
            end tell
            """
        }

        guard Shell.run("/usr/bin/osascript", ["-e", script]) != nil else {
            throw Failure(
                message: "System Events refused the change. Grant Task Manager automation access "
                    + "for System Events in System Settings › Privacy & Security › Automation."
            )
        }
    }

    private static func label(forPlist path: String) -> String? {
        if let dict = NSDictionary(contentsOfFile: path),
           let label = dict["Label"] as? String, !label.isEmpty {
            return label
        }
        // Well-formed agents name the file after the label; fall back to that.
        let file = (path as NSString).lastPathComponent
        guard file.hasSuffix(".plist") else { return nil }
        let stem = String(file.dropLast(6))
        return stem.isEmpty ? nil : stem
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Row

private struct StartupRowView: View {
    let row: StartupRow
    let columns: [TableColumnSpec]
    let isSelected: Bool

    @ObservedObject var state: TableColumnState
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            let visible = state.visibleColumns(columns)
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, spec in
                cell(spec)
                if index < visible.count - 1 {
                    Color.clear.frame(width: TableColumnState.dividerWidth)
                }
            }
        }
        .frame(height: WinTheme.Metrics.rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return WinTheme.Palette.rowSelected(scheme) }
        if isHovering { return WinTheme.Palette.rowHover(scheme) }
        return .clear
    }

    @ViewBuilder
    private func cell(_ spec: TableColumnSpec) -> some View {
        Group {
            if spec.id == "Name" {
                nameCell
            } else if spec.id == "Status" {
                Text(row.status)
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(
                        row.status == "Disabled"
                            ? WinTheme.Palette.textSecondary(scheme)
                            : WinTheme.Palette.textPrimary(scheme)
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: spec.alignment)
            } else {
                Text(spec.id == "Publisher" ? row.publisher : row.impact)
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: spec.alignment)
            }
        }
        .padding(.horizontal, WinTheme.Metrics.cellPadding)
        .frame(width: state.width(spec), alignment: spec.alignment)
        .frame(maxWidth: state.width(spec) == nil ? .infinity : nil, maxHeight: .infinity)
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)

            Text(row.name)
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .help(row.path)
    }
}
