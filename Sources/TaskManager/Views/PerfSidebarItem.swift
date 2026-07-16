import SwiftUI

/// One row in the Performance tab's left column: name, live sparkline, current value.
///
/// e.g. "CPU" / "14%  3.19 GHz", "Memory" / "18.7/32.0 GB (58%)", "Wi-Fi" / "S: 0 R: 1.2 Mbps".
struct PerfSidebarItem: View {
    var title: String
    var detail: String
    var values: [Double]
    var secondary: [Double]? = nil
    var upperBound: Double = 100
    var color: Color
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    /// Taller than the nav sidebar item: it has to fit a sparkline plus two text lines.
    private let itemHeight: CGFloat = 56
    private let sparklineWidth: CGFloat = 64

    var body: some View {
        Button(action: action) {
            HStack(spacing: WinTheme.Metrics.cellPadding) {
                // Windows' accent selection bar down the leading edge.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? WinTheme.Palette.accent(scheme) : .clear)
                    .frame(width: 3, height: 24)

                PerfGraph(
                    values: values,
                    secondary: secondary,
                    upperBound: upperBound,
                    color: color,
                    dimmed: true
                )
                .frame(width: sparklineWidth, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(WinTheme.Typography.sidebarItem)
                        .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                        .lineLimit(1)
                    Text(detail)
                        .font(WinTheme.Typography.statLabel)
                        .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, WinTheme.Metrics.cellPadding)
            .frame(height: itemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: WinTheme.Metrics.cardCornerRadius / 2)
            .fill(
                isSelected
                    ? WinTheme.Palette.rowSelected(scheme)
                    : (isHovering ? WinTheme.Palette.rowHover(scheme) : .clear)
            )
    }
}
