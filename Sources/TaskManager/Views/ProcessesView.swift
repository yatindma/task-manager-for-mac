import AppKit
import SwiftUI

/// The Processes tab: grouped, sortable, heat-mapped process table.
struct ProcessesView: View {
    init() {}

    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var app = AppState.shared
    @StateObject private var columnState = TableColumnState(tableID: "processes")
    @Environment(\.colorScheme) private var scheme

    @State private var sortColumn: ProcColumn = .name
    @State private var direction: SortDirection = .ascending
    @State private var expanded: Set<pid_t> = []
    @State private var collapsedGroups: Set<ProcKind> = []

    var body: some View {
        // Sort/filter/flatten happen once per refresh here, never inside a row body.
        let groups = buildGroups()
        let scale = heatScale()

        TableScroller(minimumWidth: columnState.minimumWidth(of: columnSpecs)) {
        VStack(spacing: 0) {
            TableHeaderView(
                columns: columnSpecs,
                sortColumnID: sortColumn.rawValue,
                direction: direction,
                onSort: sort(by:),
                state: columnState
            )

            if !monitor.hasLoaded {
                loadingState
            } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(groups, id: \.kind) { group in
                        groupHeader(group)
                        if !collapsedGroups.contains(group.kind) {
                            ForEach(group.items) { item in
                                ProcessRowView(
                                    item: item,
                                    columns: columnSpecs,
                                    scale: scale,
                                    isSelected: app.selectedPID == item.row.pid,
                                    onToggleExpand: { toggleExpand(item.row.pid) },
                                    state: columnState
                                )
                                .onTapGesture(count: 2) { goToDetails(item.row.pid) }
                                .onTapGesture { app.selectedPID = item.row.pid }
                                .contextMenu { menu(for: item) }
                            }
                        }
                    }
                }
            }
            .onDeleteCommand {
                if let pid = app.selectedPID { _ = ProcessActions.endTask(pid) }
            }
            }
        }
        }
        .background(WinTheme.Palette.card(scheme))
    }

    /// The first sample enumerates every process on the machine, so there is a
    /// beat before the table can render. An empty table reads as broken.
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Reading processes…")
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Columns

    /// Heated headings carry the system-wide total and are tinted by it.
    private var columnSpecs: [TableColumnSpec] {
        ProcColumn.allCases.map { column in
            switch column {
            case .name:
                return TableColumnSpec(
                    id: column.rawValue, title: column.rawValue,
                    defaultWidth: column.width, alignment: .leading, canHide: false
                )
            case .status:
                return TableColumnSpec(
                    id: column.rawValue, title: column.rawValue,
                    defaultWidth: column.width, alignment: .leading
                )
            case .cpu:
                return heated(column, total: monitor.cpu.usage, load: monitor.cpu.usage / 100)
            case .memory:
                return heated(
                    column, total: monitor.memory.usedPercent,
                    load: monitor.memory.usedPercent / 100
                )
            case .disk:
                let active = monitor.disks.map(\.activePercent).max() ?? 0
                return heated(column, total: active, load: active / 100)
            case .network:
                // Windows shows a network utilisation percentage; macOS exposes no
                // link utilisation, so this is throughput against the observed peak.
                // Numerator and denominator must aggregate the same thing (send +
                // receive, summed over every interface) or a busy link structurally
                // reads over 100%.
                let peak = monitor.networks.reduce(0.0) {
                    $0 + max($1.sendHistory.peak, 0) + max($1.receiveHistory.peak, 0)
                }
                let rate = monitor.networks.reduce(0.0) { $0 + $1.sendRate + $1.receiveRate }
                let share = peak > 1024 ? min(rate / peak, 1) : 0
                return heated(column, total: share * 100, load: share)
            case .gpu:
                let util = monitor.gpus.map(\.utilization).max() ?? 0
                return heated(column, total: util, load: util / 100)
            case .powerUsage, .powerTrend:
                return TableColumnSpec(
                    id: column.rawValue, title: column.rawValue, defaultWidth: column.width
                )
            }
        }
    }

    private func heated(_ column: ProcColumn, total: Double, load: Double) -> TableColumnSpec {
        TableColumnSpec(
            id: column.rawValue,
            title: column.rawValue,
            defaultWidth: column.width,
            subtitle: WinTheme.percent(total),
            heat: load
        )
    }

    // MARK: - Grouping, filtering, sorting

    private struct ProcGroup {
        let kind: ProcKind
        let count: Int
        let items: [ProcessRowItem]
    }

    private func buildGroups() -> [ProcGroup] {
        let query = app.searchText.trimmingCharacters(in: .whitespaces).lowercased()

        return [ProcKind.app, .background, .system].compactMap { kind in
            let roots = monitor.processes
                .filter { $0.kind == kind }
                .compactMap { filter($0, query: query) }
            guard !roots.isEmpty else { return nil }

            let sorted = sortTree(roots)
            var items: [ProcessRowItem] = []
            flatten(sorted, level: 0, into: &items)
            return ProcGroup(kind: kind, count: roots.count, items: items)
        }
    }

    /// Keeps a row when it matches, or when any descendant does.
    private func filter(_ row: ProcRow, query: String) -> ProcRow? {
        guard !query.isEmpty else { return row }
        let children = row.children.compactMap { filter($0, query: query) }
        let matches = row.displayName.lowercased().contains(query)
            || row.path.lowercased().contains(query)
            || String(row.pid).contains(query)
        guard matches || !children.isEmpty else { return nil }
        var copy = row
        copy.children = matches ? row.children : children
        return copy
    }

    private func sortTree(_ rows: [ProcRow]) -> [ProcRow] {
        rows.map { row -> ProcRow in
            var copy = row
            copy.children = sortTree(row.children)
            return copy
        }
        .sorted(by: precedes)
    }

    private func precedes(_ a: ProcRow, _ b: ProcRow) -> Bool {
        let ascending = direction == .ascending
        switch sortColumn {
        case .name:
            let r = a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            return ascending ? r : !r
        case .status:
            let r = a.status.label < b.status.label
            return ascending ? r : !r
        case .cpu:
            return compare(a.totalCPU, b.totalCPU, ascending)
        case .memory:
            return compare(Double(a.totalMemory), Double(b.totalMemory), ascending)
        case .disk:
            return compare(a.totalDisk, b.totalDisk, ascending)
        case .network:
            return compare(a.totalNetwork, b.totalNetwork, ascending)
        case .gpu:
            return compare(a.totalGPU, b.totalGPU, ascending)
        case .powerUsage:
            return compare(a.totalCPU, b.totalCPU, ascending)
        case .powerTrend:
            return compare(totalCPUTrend(a), totalCPUTrend(b), ascending)
        }
    }

    /// Rolling per-pid CPU average, summed over a collapsed row's subtree the
    /// same way `totalCPU` sums the instantaneous value.
    private func totalCPUTrend(_ row: ProcRow) -> Double {
        ProcessPowerTrend.shared.value(for: row.pid)
            + row.children.reduce(0) { $0 + totalCPUTrend($1) }
    }

    private func compare(_ a: Double, _ b: Double, _ ascending: Bool) -> Bool {
        a == b ? false : (ascending ? a < b : a > b)
    }

    private func flatten(_ rows: [ProcRow], level: Int, into items: inout [ProcessRowItem]) {
        for row in rows {
            let isExpanded = expanded.contains(row.pid)
            items.append(ProcessRowItem(row: row, level: level, isExpanded: isExpanded))
            if isExpanded && !row.children.isEmpty {
                flatten(row.children, level: level + 1, into: &items)
            }
        }
    }

    /// Scaled against system-wide absolutes, not the busiest row this tick —
    /// otherwise the busiest visible row always hits the top heat stop by
    /// construction, and the denominator would shift whenever a group expands.
    private func heatScale() -> ProcessHeatScale {
        let totalDiskRate = monitor.disks.reduce(0.0) { $0 + $1.readRate + $1.writeRate }
        let diskBusyFraction = (monitor.disks.map(\.activePercent).max() ?? 0) / 100

        let ratedCapacity = monitor.networks.reduce(0.0) { partial, net in
            net.linkSpeedMbps > 0 ? partial + net.linkSpeedMbps * 1_000_000 / 8 : partial
        }
        // No interface reports a link speed (e.g. a VPN-only utun): fall back to
        // the aggregate 60 s observed peak rather than a fixed constant.
        let observedPeak = monitor.networks.reduce(0.0) {
            $0 + $1.sendHistory.peak + $1.receiveHistory.peak
        }
        let networkCapacity = ratedCapacity > 0 ? ratedCapacity : observedPeak

        return ProcessHeatScale(
            totalRAM: Double(monitor.memory.totalBytes),
            totalDiskRate: totalDiskRate,
            diskBusyFraction: diskBusyFraction,
            networkCapacity: networkCapacity
        )
    }

    // MARK: - Header

    @ViewBuilder
    private func groupHeader(_ group: ProcGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.kind)

        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                .frame(width: 10)
            Text("\(group.kind.groupTitle) (\(group.count))")
                .font(WinTheme.Typography.rowEmphasis)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WinTheme.Metrics.cellPadding)
        .frame(height: WinTheme.Metrics.rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WinTheme.Palette.header(scheme))
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { collapsedGroups.remove(group.kind) } else { collapsedGroups.insert(group.kind) }
        }
    }

    // MARK: - Actions

    private func sort(by columnID: String) {
        guard let column = ProcColumn(rawValue: columnID) else { return }
        if column == sortColumn {
            direction = direction.flipped
        } else {
            sortColumn = column
            // Windows opens a metric column biggest-first.
            direction = column == .name ? .ascending : .descending
        }
    }

    private func toggleExpand(_ pid: pid_t) {
        if expanded.contains(pid) { expanded.remove(pid) } else { expanded.insert(pid) }
    }

    private func goToDetails(_ pid: pid_t) {
        app.selectedPID = pid
        app.tab = .details
    }

    @ViewBuilder
    private func menu(for item: ProcessRowItem) -> some View {
        let row = item.row

        if item.hasChildren {
            Button(item.isExpanded ? "Collapse" : "Expand") { toggleExpand(row.pid) }
            Divider()
        }

        Button("End task") { _ = ProcessActions.endTask(row.pid) }
        Button("End process tree") { _ = ProcessActions.endTree(row.pid) }

        if row.status == .suspended {
            Button("Resume") { _ = ProcessActions.resume(row.pid) }
        } else {
            Button("Suspend") { _ = ProcessActions.suspend(row.pid) }
        }

        Divider()

        Button("Go to details") { goToDetails(row.pid) }
        Button("Open file location") { ProcessActions.revealInFinder(row.path) }
            .disabled(row.path.isEmpty)
        Button("Search online") { ProcessActions.searchOnline(row.name) }
        Button("Properties") { showProperties(row.path) }
            .disabled(row.path.isEmpty)
    }

    /// Finder's Get Info window has no public API, so ask Finder for it directly.
    private func showProperties(_ path: String) {
        guard !path.isEmpty else { return }
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
