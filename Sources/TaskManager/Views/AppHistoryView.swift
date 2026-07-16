import AppKit
import SwiftUI

/// The zero point for App history.
///
/// `AppHistoryStore` only ever accumulates, so "Delete usage history" is
/// implemented as a baseline: the cumulative totals at the moment of the delete
/// are remembered and subtracted from everything the store reports afterwards.
/// The store's JSON is removed at the same time so a relaunch starts clean.
@MainActor
final class AppHistoryBaseline: ObservableObject {

    private struct Mark: Codable {
        var cpuTimeSeconds: Double
        var networkBytes: UInt64
        var meteredNetworkBytes: UInt64
    }

    private static let marksKey = "appHistory.baseline"
    private static let sinceKey = "appHistory.since"

    private let defaults = UserDefaults.standard

    @Published private(set) var since: Date
    private var marks: [String: Mark]

    /// Same location AppHistoryStore persists to.
    private let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TaskManager/app-history.json")
    }()

    init() {
        let stored = defaults.object(forKey: Self.sinceKey) as? Date
        since = stored ?? Date()

        if let data = defaults.data(forKey: Self.marksKey),
           let decoded = try? JSONDecoder().decode([String: Mark].self, from: data) {
            marks = decoded
        } else {
            marks = [:]
        }

        // Deferred until every stored property is initialised — Swift forbids touching
        // self before that, and `marks` above is assigned after `since`.
        if stored == nil {
            defaults.set(since, forKey: Self.sinceKey)
        }
    }

    /// The store's rows with the baseline removed. Apps with nothing left to
    /// show since the last delete drop out entirely, as they do on Windows.
    func adjusted(_ rows: [AppHistoryRow]) -> [AppHistoryRow] {
        rows.compactMap { row in
            guard let mark = marks[row.bundleID] else { return row }

            var out = row
            out.cpuTimeSeconds = max(row.cpuTimeSeconds - mark.cpuTimeSeconds, 0)
            out.networkBytes = row.networkBytes &- min(row.networkBytes, mark.networkBytes)
            out.meteredNetworkBytes = row.meteredNetworkBytes &- min(row.meteredNetworkBytes, mark.meteredNetworkBytes)

            let empty = out.cpuTimeSeconds < 0.5 && out.networkBytes == 0 && out.meteredNetworkBytes == 0
            return empty ? nil : out
        }
    }

    func clear(currentRows rows: [AppHistoryRow]) {
        marks = Dictionary(
            uniqueKeysWithValues: rows.map { row in
                (row.bundleID, Mark(
                    cpuTimeSeconds: row.cpuTimeSeconds,
                    networkBytes: row.networkBytes,
                    meteredNetworkBytes: row.meteredNetworkBytes
                ))
            }
        )
        if let data = try? JSONEncoder().encode(marks) {
            defaults.set(data, forKey: Self.marksKey)
        }

        since = Date()
        defaults.set(since, forKey: Self.sinceKey)

        // Best effort: the live store keeps its own copy in memory, which the
        // baseline above already cancels out. Removing the file stops a relaunch
        // from resurrecting the deleted totals.
        try? FileManager.default.removeItem(at: storeURL)
    }
}

// MARK: - Tab

/// The App history tab: cumulative per-app resource usage for this user account.
struct AppHistoryView: View {
    init() {}

    private enum Column: String, CaseIterable {
        case name = "Name"
        case cpuTime = "CPU time"
        case network = "Network"
        case metered = "Metered network"

        var width: CGFloat? {
            switch self {
            case .name: return nil
            case .cpuTime: return 96
            case .network: return 100
            case .metered: return 128
            }
        }

        var alignment: Alignment { self == .name ? .leading : .trailing }
    }

    @ObservedObject private var monitor = SystemMonitor.shared
    @StateObject private var baseline = AppHistoryBaseline()
    @StateObject private var columnState = TableColumnState(tableID: "appHistory")
    @Environment(\.colorScheme) private var scheme

    @State private var sortColumn: Column = .cpuTime
    @State private var direction: SortDirection = .descending

    var body: some View {
        let rows = sorted(baseline.adjusted(monitor.appHistory))

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

                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                AppHistoryRowView(row: row, columns: columnSpecs, state: columnState)
                            }
                        }
                    }
                }
            }
        }
        .background(WinTheme.Palette.card(scheme))
        .onReceive(NotificationCenter.default.publisher(for: .primaryCommandInvoked)) { note in
            guard note.object as? Tab == .appHistory else { return }
            baseline.clear(currentRows: monitor.appHistory)
            monitor.refreshNow()
        }
    }

    // MARK: - Header blurb

    private var blurb: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Resource usage since \(Self.sinceFormatter.string(from: baseline.since)) for the current user account.")
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))

            Button("Delete usage history") {
                baseline.clear(currentRows: monitor.appHistory)
                monitor.refreshNow()
            }
            .buttonStyle(.link)
            .font(WinTheme.Typography.row)
            .foregroundStyle(WinTheme.Palette.accent(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private static let sinceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - Columns

    private var columnSpecs: [TableColumnSpec] {
        Column.allCases.map { column in
            TableColumnSpec(
                id: column.rawValue,
                title: column.rawValue,
                defaultWidth: column.width,
                alignment: column.alignment,
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
            direction = column == .name ? .ascending : .descending
        }
    }

    private func sorted(_ rows: [AppHistoryRow]) -> [AppHistoryRow] {
        let ascending = direction == .ascending
        return rows.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .name:
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .cpuTime:
                result = a.cpuTimeSeconds < b.cpuTimeSeconds
            case .network:
                result = a.networkBytes < b.networkBytes
            case .metered:
                result = a.meteredNetworkBytes < b.meteredNetworkBytes
            }
            return ascending ? result : !result
        }
    }

    /// Windows shows CPU time as h:mm:ss, never as a byte size.
    static func cpuTime(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Row

private struct AppHistoryRowView: View {
    let row: AppHistoryRow
    let columns: [TableColumnSpec]

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
        .background(isHovering ? WinTheme.Palette.rowHover(scheme) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func cell(_ spec: TableColumnSpec) -> some View {
        Group {
            if spec.id == "Name" {
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
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Text(row.name)
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    private func text(for spec: TableColumnSpec) -> String {
        switch spec.id {
        case "CPU time": return AppHistoryView.cpuTime(row.cpuTimeSeconds)
        case "Network": return WinTheme.bytes(row.networkBytes)
        case "Metered network": return WinTheme.bytes(row.meteredNetworkBytes)
        default: return ""
        }
    }
}
