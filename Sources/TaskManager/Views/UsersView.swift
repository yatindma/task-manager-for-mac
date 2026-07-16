import AppKit
import SwiftUI

/// The Users tab: signed-in accounts as expandable parents over their processes,
/// heat-mapped with the same scale the Processes tab uses.
struct UsersView: View {
    init() {}

    private enum Column: String, CaseIterable {
        case user = "User"
        case status = "Status"
        case cpu = "CPU"
        case memory = "Memory"

        var width: CGFloat? {
            switch self {
            case .user: return nil
            case .status: return 110
            case .cpu: return 72
            case .memory: return 92
            }
        }

        var alignment: Alignment { self == .user || self == .status ? .leading : .trailing }
        var isHeated: Bool { self == .cpu || self == .memory }
    }

    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var app = AppState.shared
    @StateObject private var columnState = TableColumnState(tableID: "users")
    @Environment(\.colorScheme) private var scheme

    @State private var expanded: Set<String> = []

    var body: some View {
        let totalRAM = Double(monitor.memory.totalBytes)

        TableScroller(minimumWidth: columnState.minimumWidth(of: columnSpecs)) {
        VStack(spacing: 0) {
            TableHeaderView(
                columns: columnSpecs,
                sortColumnID: Column.user.rawValue,
                direction: .ascending,
                onSort: { _ in },
                state: columnState
            )

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(monitor.users) { user in
                        UserOutlineRow(
                            title: user.fullName.isEmpty ? user.username : user.fullName,
                            subtitle: user.fullName.isEmpty ? "" : user.username,
                            icon: Self.userIcon,
                            status: user.status,
                            cpu: user.cpu,
                            memoryBytes: user.memoryBytes,
                            level: 0,
                            isExpanded: expanded.contains(user.id),
                            hasChildren: !user.processes.isEmpty,
                            isSelected: false,
                            columns: columnSpecs,
                            totalRAM: totalRAM,
                            onToggleExpand: { toggle(user.id) },
                            state: columnState
                        )
                        .contextMenu { userMenu(user) }

                        if expanded.contains(user.id) {
                            // UserSampler already flattens each user's process tree into
                            // `processes`; do not flatten again here or every child appears twice.
                            ForEach(user.processes) { proc in
                                UserOutlineRow(
                                    title: proc.displayName,
                                    subtitle: "",
                                    icon: proc.icon,
                                    status: proc.status.label,
                                    cpu: proc.cpu,
                                    memoryBytes: proc.memoryBytes,
                                    level: 1,
                                    isExpanded: false,
                                    hasChildren: false,
                                    isSelected: app.selectedPID == proc.pid,
                                    columns: columnSpecs,
                                    totalRAM: totalRAM,
                                    onToggleExpand: {},
                                    state: columnState
                                )
                                .onTapGesture { app.selectedPID = proc.pid }
                                .contextMenu { processMenu(proc) }
                            }
                        }
                    }
                }
            }
        }
        }
        .background(WinTheme.Palette.card(scheme))
    }

    // MARK: - Columns

    /// The heated headings carry the machine-wide totals, matching Processes.
    private var columnSpecs: [TableColumnSpec] {
        Column.allCases.map { column in
            switch column {
            case .cpu:
                return TableColumnSpec(
                    id: column.rawValue, title: column.rawValue,
                    defaultWidth: column.width, alignment: column.alignment,
                    subtitle: WinTheme.percent(monitor.cpu.usage),
                    heat: monitor.cpu.usage / 100
                )
            case .memory:
                return TableColumnSpec(
                    id: column.rawValue, title: column.rawValue,
                    defaultWidth: column.width, alignment: column.alignment,
                    subtitle: WinTheme.percent(monitor.memory.usedPercent),
                    heat: monitor.memory.usedPercent / 100
                )
            default:
                return TableColumnSpec(
                    id: column.rawValue, title: column.rawValue,
                    defaultWidth: column.width, alignment: column.alignment,
                    canHide: column != .user
                )
            }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func userMenu(_ user: UserRow) -> some View {
        Button(expanded.contains(user.id) ? "Collapse" : "Expand") { toggle(user.id) }
            .disabled(user.processes.isEmpty)

        Divider()

        // macOS has no supported way to log another account out from a second
        // process, and none at all for the console user. Shown, but inert.
        Button("Disconnect") {}
            .disabled(true)
            .help("macOS provides no supported way to disconnect a signed-in account.")

        Button("Manage user accounts") {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func processMenu(_ proc: ProcRow) -> some View {
        Button("End task") { _ = ProcessActions.endTask(proc.pid) }
        Button("Go to details") {
            app.selectedPID = proc.pid
            app.tab = .details
        }
        Button("Open file location") { ProcessActions.revealInFinder(proc.path) }
            .disabled(proc.path.isEmpty)
    }

    // MARK: - Helpers

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private static let userIcon = NSImage(named: NSImage.userName)
}

// MARK: - Row

/// One outline row, used for both the user parent and its process children.
private struct UserOutlineRow: View {
    let title: String
    let subtitle: String
    let icon: NSImage?
    let status: String
    let cpu: Double
    let memoryBytes: UInt64
    let level: Int
    let isExpanded: Bool
    let hasChildren: Bool
    let isSelected: Bool
    let columns: [TableColumnSpec]
    let totalRAM: Double
    let onToggleExpand: () -> Void

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
            if spec.id == "User" {
                nameCell
            } else {
                Text(text(for: spec))
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: spec.alignment)
            }
        }
        .padding(.horizontal, WinTheme.Metrics.cellPadding)
        .frame(width: state.width(spec), alignment: spec.alignment)
        .frame(maxWidth: state.width(spec) == nil ? .infinity : nil, maxHeight: .infinity)
        .background(heatColor(for: spec))
    }

    private var nameCell: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(level) * WinTheme.Metrics.indentPerLevel, height: 1)

            Group {
                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggleExpand)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)

            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Text(title)
                .font(level == 0 ? WinTheme.Typography.rowEmphasis : WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                .lineLimit(1)
                .truncationMode(.tail)

            if !subtitle.isEmpty {
                Text("(\(subtitle))")
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private func text(for spec: TableColumnSpec) -> String {
        switch spec.id {
        case "Status": return status
        case "CPU": return WinTheme.percent(cpu)
        case "Memory": return WinTheme.bytes(memoryBytes)
        default: return ""
        }
    }

    private func heatColor(for spec: TableColumnSpec) -> Color {
        switch spec.id {
        case "CPU":
            return WinTheme.heat(cpu / 100, scheme)
        case "Memory":
            guard totalRAM > 0 else { return .clear }
            return WinTheme.heat(Double(memoryBytes) / totalRAM, scheme)
        default:
            return .clear
        }
    }
}
