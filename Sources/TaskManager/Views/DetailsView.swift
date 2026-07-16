import AppKit
import Darwin
import SwiftUI

// MARK: - Generic table header

/// A column that `WinTableHeader` can lay out. Both Details and Services define
/// their own column enum; neither reuses `ProcColumn` (that one models the
/// Processes tab's heated columns, which Details/Services do not have).
protocol WinTableColumn: Identifiable, Hashable where ID == String {
    var title: String { get }
    var defaultWidth: CGFloat { get }
    var minWidth: CGFloat { get }
    /// The one column that soaks up leftover width, as Name does in Windows.
    var isFlexible: Bool { get }
    var alignment: Alignment { get }
}

extension WinTableColumn {
    var minWidth: CGFloat { 48 }
    var isFlexible: Bool { false }
    var alignment: Alignment { .leading }
}

extension Collection where Element: WinTableColumn {
    /// Width the visible columns need before the flexible one is squeezed. Feeds
    /// TableScroller so these tables scroll rather than shove the sidebar off-screen.
    func minimumWidth(visible: Set<String>, widths: [String: CGFloat]) -> CGFloat {
        filter { visible.contains($0.id) }
            .reduce(CGFloat.zero) { total, column in
                total + (column.isFlexible ? 220 : (widths[column.id] ?? column.defaultWidth))
            }
    }
}

/// Windows-style sortable, resizable header with a show/hide columns context menu.
struct WinTableHeader<C: WinTableColumn>: View {
    let allColumns: [C]
    @Binding var visible: Set<C.ID>
    @Binding var widths: [C.ID: CGFloat]
    @Binding var sortColumn: C
    @Binding var sortDirection: SortDirection

    @Environment(\.colorScheme) private var scheme
    /// Width at the moment a resize drag began, so the drag is absolute not cumulative.
    @State private var resizeBase: [C.ID: CGFloat] = [:]

    private var shown: [C] { allColumns.filter { visible.contains($0.id) } }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(shown) { column in
                headerCell(column)
            }
        }
        .frame(height: WinTheme.Metrics.headerHeight)
        .background(WinTheme.Palette.header(scheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WinTheme.Palette.border(scheme))
                .frame(height: 1)
        }
        .contextMenu { columnsMenu }
    }

    private func headerCell(_ column: C) -> some View {
        HStack(spacing: 4) {
            if column.alignment == .trailing { Spacer(minLength: 0) }
            Text(column.title)
                .font(WinTheme.Typography.columnHeader)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                .lineLimit(1)
            if sortColumn == column {
                Image(systemName: sortDirection.symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WinTheme.Palette.accent(scheme))
            }
            if column.alignment != .trailing { Spacer(minLength: 0) }
        }
        .padding(.horizontal, WinTheme.Metrics.cellPadding)
        .frame(maxWidth: column.isFlexible ? .infinity : nil, alignment: .leading)
        .frame(width: column.isFlexible ? nil : width(of: column))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if sortColumn == column {
                sortDirection = sortDirection.flipped
            } else {
                sortColumn = column
                sortDirection = .descending
            }
        }
        .overlay(alignment: .trailing) { if !column.isFlexible { resizeHandle(column) } }
    }

    private func resizeHandle(_ column: C) -> some View {
        Rectangle()
            .fill(WinTheme.Palette.gridLine(scheme))
            .frame(width: 1)
            .padding(.vertical, 8)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = resizeBase[column.id] ?? width(of: column)
                        resizeBase[column.id] = base
                        widths[column.id] = max(column.minWidth, base + value.translation.width)
                    }
                    .onEnded { _ in resizeBase[column.id] = nil }
            )
    }

    @ViewBuilder private var columnsMenu: some View {
        ForEach(allColumns) { column in
            Button {
                if visible.contains(column.id) {
                    // Never let the table become empty, and never hide the sorted column away.
                    guard visible.count > 1 else { return }
                    visible.remove(column.id)
                    if sortColumn == column, let first = shown.first { sortColumn = first }
                } else {
                    visible.insert(column.id)
                }
            } label: {
                if visible.contains(column.id) {
                    Label(column.title, systemImage: "checkmark")
                } else {
                    Text(column.title)
                }
            }
        }
    }

    private func width(of column: C) -> CGFloat {
        widths[column.id] ?? column.defaultWidth
    }
}

/// Applies the header's width/alignment to a row cell so columns stay aligned.
private struct ColumnCell<C: WinTableColumn>: ViewModifier {
    let column: C
    let widths: [C.ID: CGFloat]

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, WinTheme.Metrics.cellPadding)
            .frame(maxWidth: column.isFlexible ? .infinity : nil, alignment: column.alignment)
            .frame(width: column.isFlexible ? nil : (widths[column.id] ?? column.defaultWidth),
                   alignment: column.alignment)
    }
}

extension View {
    func columnCell<C: WinTableColumn>(_ column: C, _ widths: [C.ID: CGFloat]) -> some View {
        modifier(ColumnCell(column: column, widths: widths))
    }
}

// MARK: - Details columns

enum DetailColumn: String, CaseIterable, Identifiable, WinTableColumn {
    case name = "Name"
    case pid = "PID"
    case status = "Status"
    case user = "User name"
    case cpu = "CPU"
    case memory = "Memory (active private working set)"
    case architecture = "Architecture"
    case description = "Description"
    case threads = "Threads"
    case handles = "Handles"
    case startTime = "Start time"
    case path = "Path"

    var id: String { rawValue }
    var title: String { rawValue }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 180
        case .pid: return 64
        case .status: return 84
        case .user: return 104
        case .cpu: return 56
        case .memory: return 168
        case .architecture: return 88
        case .description: return 200
        case .threads: return 64
        case .handles: return 68
        case .startTime: return 148
        case .path: return 320
        }
    }

    var isFlexible: Bool { self == .name }

    var alignment: Alignment {
        switch self {
        case .pid, .cpu, .memory, .threads, .handles: return .trailing
        default: return .leading
        }
    }
}

/// Windows priority classes, mapped to the closest macOS nice value.
/// macOS has no realtime or "above normal" scheduling class reachable through
/// `setpriority`, so those map honestly to the nearest nice we can actually set.
private enum PriorityClass: String, CaseIterable, Identifiable {
    case realtime = "Realtime"
    case high = "High"
    case aboveNormal = "Above normal"
    case normal = "Normal"
    case belowNormal = "Below normal"
    case low = "Low"

    var id: String { rawValue }

    var nice: Int32 {
        switch self {
        case .realtime: return -20      // closest reachable; not true realtime
        case .high: return -10
        case .aboveNormal: return -5    // no distinct macOS class
        case .normal: return 0
        case .belowNormal: return 5
        case .low: return 19
        }
    }
}

/// Executable architecture is stable for a process's lifetime, so resolve once.
@MainActor
private final class ArchCache {
    static let shared = ArchCache()
    private var cache: [pid_t: String] = [:]

    func arch(for pid: pid_t) -> String {
        if let cached = cache[pid] { return cached }
        let value = ArchCache.compute(pid)
        cache[pid] = value
        return value
    }

    private static func compute(_ pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid) {
            switch app.executableArchitecture {
            case NSBundleExecutableArchitectureARM64: return "ARM64"
            case NSBundleExecutableArchitectureX86_64: return "x64"
            case NSBundleExecutableArchitectureI386: return "x86"
            default: break
            }
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return "—" }
        let pLP64: Int32 = 0x0000_0004  // P_LP64 from <sys/proc.h>, not exported to Swift
        guard info.kp_proc.p_flag & pLP64 != 0 else { return "x86" }
        #if arch(arm64)
        return "ARM64"
        #else
        return "x64"
        #endif
    }
}

private let startTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .medium
    return f
}()

// MARK: - Details view

/// The Windows Details tab: one flat, untinted row per process.
struct DetailsView: View {
    init() {}

    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.colorScheme) private var scheme

    @State private var visible: Set<String> = Set(
        [DetailColumn.name, .pid, .status, .user, .cpu, .memory, .architecture, .description]
            .map(\.id)
    )
    @State private var widths: [String: CGFloat] = [:]
    @State private var sortColumn: DetailColumn = .name
    @State private var sortDirection: SortDirection = .ascending
    @State private var hoveredPID: pid_t?
    @State private var priorityFailure: String?

    /// Windows' Details rows are tighter than the Processes rows.
    private var rowHeight: CGFloat { WinTheme.Metrics.rowHeight - 6 }

    private var shownColumns: [DetailColumn] {
        DetailColumn.allCases.filter { visible.contains($0.id) }
    }

    private var rows: [ProcRow] {
        let flat = DetailsView.flatten(monitor.processes)
        let query = app.searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? flat : flat.filter { matches($0, query) }
        return filtered.sorted(by: ordered)
    }

    var body: some View {
        TableScroller(
            minimumWidth: DetailColumn.allCases.minimumWidth(visible: visible, widths: widths)
        ) {
        VStack(spacing: 0) {
            WinTableHeader(
                allColumns: DetailColumn.allCases,
                visible: $visible,
                widths: $widths,
                sortColumn: $sortColumn,
                sortDirection: $sortDirection
            )
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.pid)
                        }
                    }
                }
                .onAppear { scroll(proxy, to: app.selectedPID) }
                .onChange(of: app.selectedPID) { _, pid in scroll(proxy, to: pid) }
            }
        }
        }
        .background(WinTheme.Palette.card(scheme))
        .alert(
            "Couldn't change priority",
            isPresented: Binding(get: { priorityFailure != nil },
                                 set: { if !$0 { priorityFailure = nil } })
        ) {
            Button("OK", role: .cancel) { priorityFailure = nil }
        } message: {
            Text(priorityFailure ?? "")
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to pid: pid_t?) {
        guard let pid, rows.contains(where: { $0.pid == pid }) else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(pid, anchor: .center) }
    }

    // MARK: Row

    private func rowView(_ row: ProcRow) -> some View {
        HStack(spacing: 0) {
            ForEach(shownColumns) { column in
                cell(row, column)
                    .columnCell(column, widths)
            }
        }
        .font(WinTheme.Typography.row)
        // No heatmap: the Windows Details tab is flat and untinted.
        .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
        .frame(height: rowHeight)
        .background(background(for: row))
        .contentShape(Rectangle())
        .onHover { hoveredPID = $0 ? row.pid : (hoveredPID == row.pid ? nil : hoveredPID) }
        .onTapGesture { app.selectedPID = row.pid }
        .contextMenu { rowMenu(row) }
    }

    private func background(for row: ProcRow) -> Color {
        if app.selectedPID == row.pid { return WinTheme.Palette.rowSelected(scheme) }
        if hoveredPID == row.pid { return WinTheme.Palette.rowHover(scheme) }
        return .clear
    }

    @ViewBuilder
    private func cell(_ row: ProcRow, _ column: DetailColumn) -> some View {
        switch column {
        case .name:
            Text(row.name).lineLimit(1).truncationMode(.middle)
        case .pid:
            Text(String(row.pid)).font(WinTheme.Typography.mono)
        case .status:
            Text(row.status == .running ? "Running" : row.status.label)
        case .user:
            Text(row.user).lineLimit(1)
        case .cpu:
            Text(WinTheme.percent(row.cpu)).font(WinTheme.Typography.mono)
        case .memory:
            Text(WinTheme.bytes(row.memoryBytes)).font(WinTheme.Typography.mono)
        case .architecture:
            Text(ArchCache.shared.arch(for: row.pid))
        case .description:
            Text(row.displayName == row.name ? "—" : row.displayName)
                .lineLimit(1).truncationMode(.tail)
        case .threads:
            Text(String(row.threads)).font(WinTheme.Typography.mono)
        case .handles:
            Text(row.handles > 0 ? String(row.handles) : "—").font(WinTheme.Typography.mono)
        case .startTime:
            Text(startTimeFormatter.string(from: row.startTime))
        case .path:
            Text(row.path.isEmpty ? "—" : row.path).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func rowMenu(_ row: ProcRow) -> some View {
        Button("End task") { _ = ProcessActions.endTask(row.pid) }
        Button("End process tree") { _ = ProcessActions.endTree(row.pid) }

        Menu("Set priority") {
            ForEach(PriorityClass.allCases) { priority in
                Button(priority.rawValue) { setPriority(priority, on: row.pid) }
            }
        }

        // macOS exposes no per-process CPU affinity API (thread affinity tags are
        // only a scheduling hint, and not settable from another process), so this
        // stays visible-but-disabled rather than pretending to work.
        Button("Set affinity") {}
            .disabled(true)
            .help("macOS does not expose a CPU affinity API for other processes.")

        Divider()
        Button("Open file location") { ProcessActions.revealInFinder(row.path) }
            .disabled(row.path.isEmpty)
        Button("Search online") { ProcessActions.searchOnline(row.name) }
        Button("Properties") { showProperties(row.path) }
            .disabled(row.path.isEmpty)
        Button("Go to service(s)") {
            app.searchText = String(row.pid)
            app.tab = .services
        }
    }

    private func setPriority(_ priority: PriorityClass, on pid: pid_t) {
        errno = 0
        if setpriority(PRIO_PROCESS, id_t(pid), priority.nice) != 0 {
            let reason = String(cString: strerror(errno))
            priorityFailure = "Setting \"\(priority.rawValue)\" on PID \(pid) failed: \(reason). "
                + "Raising a process's priority needs administrator rights on macOS."
        }
    }

    /// macOS has no Windows-style properties sheet; the Finder Info window is the
    /// closest native equivalent.
    private func showProperties(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        do {
            try task.run()
        } catch {
            ProcessActions.revealInFinder(path)
        }
    }

    // MARK: Data

    private static func flatten(_ rows: [ProcRow]) -> [ProcRow] {
        rows.flatMap { row -> [ProcRow] in
            var out = row
            out.children = []
            return [out] + flatten(row.children)
        }
    }

    private func matches(_ row: ProcRow, _ query: String) -> Bool {
        row.name.localizedCaseInsensitiveContains(query)
            || row.displayName.localizedCaseInsensitiveContains(query)
            || row.user.localizedCaseInsensitiveContains(query)
            || String(row.pid) == query
    }

    private func ordered(_ a: ProcRow, _ b: ProcRow) -> Bool {
        let ascending = sortDirection == .ascending
        func text(_ lhs: String, _ rhs: String) -> Bool {
            let result = lhs.localizedCaseInsensitiveCompare(rhs)
            if result == .orderedSame { return a.pid < b.pid }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        func number(_ lhs: Double, _ rhs: Double) -> Bool {
            if lhs == rhs { return a.pid < b.pid }
            return ascending ? lhs < rhs : lhs > rhs
        }

        switch sortColumn {
        case .name: return text(a.name, b.name)
        case .pid: return number(Double(a.pid), Double(b.pid))
        case .status: return text(a.status.label, b.status.label)
        case .user: return text(a.user, b.user)
        case .cpu: return number(a.cpu, b.cpu)
        case .memory: return number(Double(a.memoryBytes), Double(b.memoryBytes))
        case .architecture:
            return text(ArchCache.shared.arch(for: a.pid), ArchCache.shared.arch(for: b.pid))
        case .description: return text(a.displayName, b.displayName)
        case .threads: return number(Double(a.threads), Double(b.threads))
        case .handles: return number(Double(a.handles), Double(b.handles))
        case .startTime:
            return number(a.startTime.timeIntervalSince1970, b.startTime.timeIntervalSince1970)
        case .path: return text(a.path, b.path)
        }
    }
}
