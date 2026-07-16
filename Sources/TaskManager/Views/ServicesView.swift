import AppKit
import Darwin
import Foundation
import SwiftUI

// MARK: - Services columns

enum ServiceColumn: String, CaseIterable, Identifiable, WinTableColumn {
    case name = "Name"
    case pid = "PID"
    case description = "Description"
    case status = "Status"
    case group = "Group"

    var id: String { rawValue }
    var title: String { rawValue }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 260
        case .pid: return 64
        case .description: return 320
        case .status: return 96
        case .group: return 140
        }
    }

    var isFlexible: Bool { self == .description }

    var alignment: Alignment {
        self == .pid ? .trailing : .leading
    }
}

// MARK: - launchd control

/// launchd's two reachable domains. `system` needs authorisation; `gui/<uid>`
/// does not, because it is the session we already own.
private enum ServiceDomain {
    case system
    case gui(uid_t)

    init(_ service: ServiceRow) {
        self = service.isSystem ? .system : .gui(getuid())
    }

    var target: String {
        switch self {
        case .system: return "system"
        case .gui(let uid): return "gui/\(uid)"
        }
    }

    var needsAuthorisation: Bool {
        if case .system = self { return true }
        return false
    }
}

private enum ServiceControl {
    enum Action {
        case start, stop, restart

        var verb: String {
            switch self {
            case .start: return "start"
            case .stop: return "stop"
            case .restart: return "restart"
            }
        }
    }

    /// Arguments to `launchctl` for the action, in the service's domain.
    static func arguments(_ action: Action, _ service: ServiceRow, _ domain: ServiceDomain) -> [String] {
        switch action {
        case .start:
            return ["bootstrap", domain.target, service.plistPath]
        case .stop:
            return ["bootout", "\(domain.target)/\(service.label)"]
        case .restart:
            return ["kickstart", "-k", "\(domain.target)/\(service.label)"]
        }
    }

    static func perform(_ action: Action, on service: ServiceRow) throws {
        let domain = ServiceDomain(service)
        let args = arguments(action, service, domain)

        if domain.needsAuthorisation {
            // A system-domain change requires root; hand it to the privileged path.
            let quoted = args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            try ProcessActions.runNewTask(command: "/bin/launchctl \(quoted)", asAdmin: true)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        try task.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            var message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.isEmpty { message = "launchctl exited with status \(task.terminationStatus)." }
            throw NSError(
                domain: "launchctl",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

// MARK: - Services view

/// The Windows Services tab, over launchd.
struct ServicesView: View {
    init() {}

    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.colorScheme) private var scheme

    @State private var visible: Set<String> = Set(ServiceColumn.allCases.map(\.id))
    @State private var widths: [String: CGFloat] = [:]
    @State private var sortColumn: ServiceColumn = .name
    @State private var sortDirection: SortDirection = .ascending
    @State private var selectedLabel: String?
    @State private var hoveredLabel: String?

    private var shownColumns: [ServiceColumn] {
        ServiceColumn.allCases.filter { visible.contains($0.id) }
    }

    private var rows: [ServiceRow] {
        let query = app.searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? monitor.services : monitor.services.filter { matches($0, query) }
        return filtered.sorted(by: ordered)
    }

    private var selectedService: ServiceRow? {
        rows.first { $0.label == selectedLabel }
    }

    var body: some View {
        VStack(spacing: 0) {
            TableScroller(
                minimumWidth: ServiceColumn.allCases.minimumWidth(visible: visible, widths: widths)
            ) {
                VStack(spacing: 0) {
                    WinTableHeader(
                        allColumns: ServiceColumn.allCases,
                        visible: $visible,
                        widths: $widths,
                        sortColumn: $sortColumn,
                        sortDirection: $sortDirection
                    )
                    if !monitor.hasLoadedSlow {
                        loadingState
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(rows) { row in
                                    rowView(row).id(row.label)
                                }
                            }
                        }
                    }
                }
            }
            bottomBar
        }
        .background(WinTheme.Palette.card(scheme))
        .onReceive(NotificationCenter.default.publisher(for: .primaryCommandInvoked)) { note in
            guard note.object as? Tab == .services,
                  let row = rows.first(where: { $0.label == selectedLabel })
            else { return }
            control(isRunning(row) ? .stop : .start, row)
        }
    }


    /// launchd and login-item scans are subprocesses that answer a few seconds
    /// after launch; an empty table in the meantime reads as broken.
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Reading launchd services…")
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Row

    private func rowView(_ row: ServiceRow) -> some View {
        let running = isRunning(row)
        return HStack(spacing: 0) {
            ForEach(shownColumns) { column in
                cell(row, column, running: running)
                    .columnCell(column, widths)
            }
        }
        .font(WinTheme.Typography.row)
        // Windows dims a stopped service's whole row.
        .foregroundStyle(running
            ? WinTheme.Palette.textPrimary(scheme)
            : WinTheme.Palette.textSecondary(scheme))
        .frame(height: WinTheme.Metrics.rowHeight)
        .background(background(for: row))
        .contentShape(Rectangle())
        .onHover { hoveredLabel = $0 ? row.label : (hoveredLabel == row.label ? nil : hoveredLabel) }
        .onTapGesture { select(row) }
        .contextMenu { rowMenu(row, running: running) }
    }

    /// The command bar resolves its Start/Stop label and enablement from the shared
    /// selection bridge (selectedPID is nil for stopped services and can't carry this).
    private func select(_ row: ServiceRow) {
        selectedLabel = row.label
        app.selectedPID = row.pid
        TabSelectionBridge.shared.selectedServiceLabel = row.label
    }

    private func background(for row: ServiceRow) -> Color {
        if selectedLabel == row.label { return WinTheme.Palette.rowSelected(scheme) }
        if hoveredLabel == row.label { return WinTheme.Palette.rowHover(scheme) }
        return .clear
    }

    @ViewBuilder
    private func cell(_ row: ServiceRow, _ column: ServiceColumn, running: Bool) -> some View {
        switch column {
        case .name:
            Text(row.label).lineLimit(1).truncationMode(.middle)
        case .pid:
            // Stopped services show no PID at all, exactly as Windows does.
            Text(running ? String(row.pid ?? 0) : "")
                .font(WinTheme.Typography.mono)
        case .description:
            Text(row.displayName).lineLimit(1).truncationMode(.tail)
        case .status:
            Text(row.status)
        case .group:
            Text(ServiceDomain(row).target)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func rowMenu(_ row: ServiceRow, running: Bool) -> some View {
        Button("Start") { control(.start, row) }
            .disabled(running)
        Button("Stop") { control(.stop, row) }
            .disabled(!running)
        Button("Restart") { control(.restart, row) }
            .disabled(!running)

        Divider()
        Button("Open Services") { openServices(row) }
        Button("Go to details") {
            guard let pid = row.pid else { return }
            app.selectedPID = pid
            app.tab = .details
        }
        .disabled(!running || row.pid == nil)
        Button("Search online") { ProcessActions.searchOnline(row.label) }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button("Open Services") { openServices(selectedService) }
        }
        .padding(.horizontal, WinTheme.Metrics.cellPadding * 2)
        .frame(height: WinTheme.Metrics.commandBarHeight)
        .background(WinTheme.Palette.header(scheme))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WinTheme.Palette.border(scheme))
                .frame(height: 1)
        }
    }

    // MARK: Actions

    private func control(_ action: ServiceControl.Action, _ row: ServiceRow) {
        do {
            try ServiceControl.perform(action, on: row)
            monitor.refreshNow()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't \(action.verb) \(row.label)"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// macOS has no services.msc; revealing the launchd plist is the closest thing.
    private func openServices(_ row: ServiceRow?) {
        if let row, !row.plistPath.isEmpty, FileManager.default.fileExists(atPath: row.plistPath) {
            ProcessActions.revealInFinder(row.plistPath)
        } else {
            ProcessActions.revealInFinder("/Library/LaunchDaemons")
        }
    }

    // MARK: Data

    private func isRunning(_ row: ServiceRow) -> Bool {
        row.pid != nil && row.status == "Running"
    }

    private func matches(_ row: ServiceRow, _ query: String) -> Bool {
        row.label.localizedCaseInsensitiveContains(query)
            || row.displayName.localizedCaseInsensitiveContains(query)
            || row.pid.map { String($0) == query } == true
    }

    private func ordered(_ a: ServiceRow, _ b: ServiceRow) -> Bool {
        let ascending = sortDirection == .ascending
        func text(_ lhs: String, _ rhs: String) -> Bool {
            let result = lhs.localizedCaseInsensitiveCompare(rhs)
            if result == .orderedSame { return a.label < b.label }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        switch sortColumn {
        case .name: return text(a.label, b.label)
        case .pid:
            // Stopped services have no PID; park them after the running ones.
            let lhs = a.pid.map(Int.init) ?? Int.max
            let rhs = b.pid.map(Int.init) ?? Int.max
            if lhs == rhs { return a.label < b.label }
            return ascending ? lhs < rhs : lhs > rhs
        case .description: return text(a.displayName, b.displayName)
        case .status: return text(a.status, b.status)
        case .group: return text(ServiceDomain(a).target, ServiceDomain(b).target)
        }
    }
}
