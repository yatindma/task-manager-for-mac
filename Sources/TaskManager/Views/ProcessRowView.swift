import AppKit
import SwiftUI

/// Denominators for the heat tint. CPU and GPU are absolute percentages;
/// Memory is a share of installed RAM; Disk and Network are relative share of
/// system throughput weighted by how busy the system actually is, so nothing
/// reads as "hot" on an idle machine.
/// Exactly one frame per cell — a fixed width where the column has one, a flexible
/// one where it doesn't. `.frame(width:)` and `.frame(maxWidth:)` are separate
/// overloads and cannot be combined, and stacking them makes SwiftUI negotiate twice
/// for every cell.
private struct CellFrame: ViewModifier {
    let width: CGFloat?
    let alignment: Alignment

    @ViewBuilder
    func body(content: Content) -> some View {
        if let width {
            // Both dimensions stated outright: nothing left to negotiate.
            content.frame(width: width, height: WinTheme.Metrics.rowHeight, alignment: alignment)
        } else {
            content.frame(maxWidth: .infinity, minHeight: WinTheme.Metrics.rowHeight,
                          maxHeight: WinTheme.Metrics.rowHeight, alignment: alignment)
        }
    }
}

struct ProcessHeatScale {
    var totalRAM: Double
    var totalDiskRate: Double
    var diskBusyFraction: Double
    var networkCapacity: Double
}

/// A flattened tree row: the process plus its depth and disclosure state.
struct ProcessRowItem: Identifiable {
    let row: ProcRow
    let level: Int
    let isExpanded: Bool

    var id: pid_t { row.pid }
    var hasChildren: Bool { !row.children.isEmpty }
}

/// One process row, Metrics.rowHeight tall, laid out against the same column
/// state as TableHeaderView.
struct ProcessRowView: View {
    let item: ProcessRowItem
    let columns: [TableColumnSpec]
    let scale: ProcessHeatScale
    let isSelected: Bool
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

    // MARK: Cells

    /// One frame per cell, deliberately.
    ///
    /// This runs ~9 times per row across ~620 rows every tick. Proposing .infinity
    /// on the inner Text and then constraining it with an outer fixed-width frame
    /// made SwiftUI re-negotiate all three boxes for all ~17,000 cells each second —
    /// a profile of the Processes tab was almost entirely LayoutEngineBox.sizeThatFits.
    /// Collapsing to a single frame that states the width outright removes the
    /// negotiation.
    @ViewBuilder
    private func cell(_ spec: TableColumnSpec) -> some View {
        let width = state.width(spec)
        Group {
            if spec.id == ProcColumn.name.rawValue {
                nameCell
            } else {
                Text(text(for: spec))
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, WinTheme.Metrics.cellPadding)
        .modifier(CellFrame(width: width, alignment: spec.alignment))
        .background(heatColor(for: spec))
    }

    private var nameCell: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(item.level) * WinTheme.Metrics.indentPerLevel, height: 1)

            Group {
                if item.hasChildren {
                    Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggleExpand)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)

            if let icon = item.row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Text(item.row.displayName)
                .font(item.level == 0 ? WinTheme.Typography.rowEmphasis : WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    // MARK: Values
    //
    // A collapsed parent shows its subtree totals; expanding it drops the row
    // back to its own values because the children are now on screen.

    private var showsTotals: Bool { item.hasChildren && !item.isExpanded }

    private var cpuValue: Double { showsTotals ? item.row.totalCPU : item.row.cpu }
    private var memoryValue: UInt64 { showsTotals ? item.row.totalMemory : item.row.memoryBytes }
    private var diskValue: Double { showsTotals ? item.row.totalDisk : item.row.diskRate }
    private var networkValue: Double { showsTotals ? item.row.totalNetwork : item.row.networkRate }
    private var gpuValue: Double { showsTotals ? item.row.totalGPU : item.row.gpu }

    private func text(for spec: TableColumnSpec) -> String {
        guard let column = ProcColumn(rawValue: spec.id) else { return "" }
        switch column {
        case .name: return item.row.displayName
        case .status: return item.row.status.label
        case .cpu: return WinTheme.percent(cpuValue)
        case .memory: return WinTheme.bytes(memoryValue)
        case .disk: return WinTheme.rate(diskValue)
        case .network: return WinTheme.rate(networkValue)
        case .gpu: return WinTheme.percent(gpuValue)
        case .powerUsage: return PowerLevel.fromCPU(cpuValue).label
        case .powerTrend: return PowerLevel.fromCPU(cpuTrendValue).label
        }
    }

    /// Rolling per-pid CPU average, kept outside ProcRow so "trend" can differ
    /// from the instantaneous "usage" column without a model change.
    private func ownCPUTrend(_ row: ProcRow) -> Double {
        ProcessPowerTrend.shared.value(for: row.pid)
    }

    private func totalCPUTrend(_ row: ProcRow) -> Double {
        ownCPUTrend(row) + row.children.reduce(0) { $0 + totalCPUTrend($1) }
    }

    private var cpuTrendValue: Double {
        showsTotals ? totalCPUTrend(item.row) : ownCPUTrend(item.row)
    }

    /// Below this share the tint would be indistinguishable from noise on an
    /// idle machine (e.g. 93 MB of 16 GB RAM), so it reads as untinted instead.
    private static let heatDeadZone: Double = 0.02

    private func heatColor(for spec: TableColumnSpec) -> Color {
        guard let column = ProcColumn(rawValue: spec.id), column.isHeated else { return .clear }
        let value = load(column)
        return WinTheme.heat(value >= Self.heatDeadZone ? value : 0, scheme)
    }

    private func load(_ column: ProcColumn) -> Double {
        switch column {
        case .cpu: return cpuValue / 100
        case .gpu: return gpuValue / 100
        case .memory:
            return scale.totalRAM > 0 ? Double(memoryValue) / scale.totalRAM : 0
        case .disk:
            guard scale.totalDiskRate > 0 else { return 0 }
            let share = diskValue / scale.totalDiskRate
            return share * scale.diskBusyFraction
        case .network:
            return scale.networkCapacity > 0 ? min(networkValue / scale.networkCapacity, 1) : 0
        default:
            return 0
        }
    }
}
