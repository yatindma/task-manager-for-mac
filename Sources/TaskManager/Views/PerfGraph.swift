import SwiftUI

/// The Performance-tab drawing primitive: a filled area chart over a fixed grid,
/// matching the Windows 11 Task Manager graph exactly.
///
/// Data is oldest-left / newest-right across the full width, so new samples slide
/// in from the right while the grid stays put.
struct PerfGraph: View {
    /// Primary series, oldest first. Typically a `RingBuffer.values`.
    var values: [Double]
    /// Optional second series, drawn as a dashed line with no fill (Network: send vs receive).
    var secondary: [Double]? = nil
    /// Top of the value axis. 100 for CPU/Memory/Disk/GPU; auto-scaled peak for Network.
    var upperBound: Double = 100
    var color: Color
    /// The small sparkline variant used in the sidebar and in per-core tiles.
    var dimmed: Bool = false
    var showsGrid: Bool = true
    var showsBorder: Bool = true

    @Environment(\.colorScheme) private var scheme

    /// Windows draws a static 10x10 lattice behind the plot.
    private let gridColumns = 10
    private let gridRows = 10

    /// When the newest sample landed. Lets the plot slide continuously between
    /// samples instead of jumping once per tick — see `body`.
    @State private var lastSampleTime = Date()

    private var lineWidth: CGFloat { dimmed ? 1 : 1.5 }
    private var lineOpacity: Double { dimmed ? 0.75 : 1 }
    private var fillOpacity: Double {
        WinTheme.Graph.fillOpacity * (dimmed ? 0.7 : 1)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas(opaque: false) { context, size in
                guard size.width > 1, size.height > 1 else { return }
                let bound = max(upperBound, 0.0001)
                let interval = max(AppState.shared.updateInterval, 0.001)
                let elapsed = timeline.date.timeIntervalSince(lastSampleTime)
                let fraction = min(max(elapsed / interval, 0), 1)

                if showsGrid { drawGrid(in: context, size: size) }

                // Secondary first so the filled primary reads on top, as Windows does.
                if let secondary, secondary.count > 1 {
                    drawSeries(secondary, in: context, size: size, bound: bound,
                               dashed: true, filled: false, fraction: fraction)
                }
                if values.count > 1 {
                    drawSeries(values, in: context, size: size, bound: bound,
                               dashed: false, filled: true, fraction: fraction)
                }

                if showsBorder {
                    let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                    context.stroke(Path(frame),
                                   with: .color(WinTheme.Palette.border(scheme)),
                                   lineWidth: 1)
                }
            }
            .drawingGroup()
        }
        // A new sample landing resets the slide; identical consecutive values leave
        // the array Equatable-equal and simply keep sliding through the reset point,
        // which is visually indistinguishable from a push since the trace is flat.
        .onChange(of: values) { _, _ in lastSampleTime = Date() }
    }

    // MARK: - Drawing

    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        var lattice = Path()
        for column in 1..<gridColumns {
            // Snap to the pixel grid so the lattice stays crisp at 1px.
            let x = (size.width * CGFloat(column) / CGFloat(gridColumns)).rounded() + 0.5
            lattice.move(to: CGPoint(x: x, y: 0))
            lattice.addLine(to: CGPoint(x: x, y: size.height))
        }
        for row in 1..<gridRows {
            let y = (size.height * CGFloat(row) / CGFloat(gridRows)).rounded() + 0.5
            lattice.move(to: CGPoint(x: 0, y: y))
            lattice.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lattice,
                       with: .color(WinTheme.Palette.gridLine(scheme).opacity(dimmed ? 0.5 : 1)),
                       lineWidth: 1)
    }

    private func drawSeries(
        _ series: [Double],
        in context: GraphicsContext,
        size: CGSize,
        bound: Double,
        dashed: Bool,
        filled: Bool,
        fraction: Double
    ) {
        let points = plotPoints(series, size: size, bound: bound, fraction: fraction)
        guard let first = points.first, let last = points.last else { return }

        var line = Path()
        line.move(to: first)
        for point in points.dropFirst() { line.addLine(to: point) }

        if filled {
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(fillOpacity)))
        }

        let style = StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: dashed ? [3, 2] : []
        )
        context.stroke(line, with: .color(color.opacity(lineOpacity)), style: style)
    }

    /// Maps `series` (oldest-left/newest-right) to points, then slides the whole
    /// trace left by `fraction` of one sample step so it creeps continuously
    /// toward the next sample instead of jumping when it lands. A phantom point
    /// one step beyond the left edge keeps that slide looking continuous as it
    /// clips out of the canvas rather than popping.
    private func plotPoints(_ series: [Double], size: CGSize, bound: Double, fraction: Double) -> [CGPoint] {
        guard series.count > 1 else { return [] }
        let step = size.width / CGFloat(series.count - 1)
        let shift = CGFloat(fraction) * step

        func y(_ value: Double) -> CGFloat {
            let clamped = min(max(value, 0), bound)
            return size.height * (1 - CGFloat(clamped / bound))
        }

        var points: [CGPoint] = [CGPoint(x: -step - shift, y: y(series[0]))]
        points.append(contentsOf: series.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step - shift, y: y(value))
        })
        return points
    }
}

// MARK: - Logical processors

/// Per-core history. `CPUStats.perCore` only carries the instantaneous sample, so this
/// keeps the rolling window — as a singleton, so it survives `MultiCoreGraph` being torn
/// down and recreated when the user switches resource or toggles graph mode. Fed by
/// `PerformanceView` on every `monitor.cpu` sample regardless of what is on screen.
@MainActor
final class CoreHistoryStore: ObservableObject {
    static let shared = CoreHistoryStore()
    private init() {}

    @Published private(set) var histories: [RingBuffer] = []

    func record(_ perCore: [Double]) {
        if histories.count != perCore.count {
            histories = Array(repeating: RingBuffer(), count: perCore.count)
        }
        for index in perCore.indices {
            histories[index].push(perCore[index])
        }
    }
}

/// The CPU "Logical processors" view: one mini graph per core, tiled.
struct MultiCoreGraph: View {
    var color: Color

    @ObservedObject private var store = CoreHistoryStore.shared

    /// Windows lays cores out wider-than-tall (8 cores -> 4x2, not 3x3).
    private var columnCount: Int {
        let count = max(store.histories.count, 1)
        return min(max(Int((Double(count) * 1.6).squareRoot().rounded()), 1), 8)
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let rows = max(Int(ceil(Double(store.histories.count) / Double(columnCount))), 1)
            let tileHeight = max((geometry.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows), 0)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
                spacing: spacing
            ) {
                ForEach(Array(store.histories.enumerated()), id: \.offset) { _, history in
                    PerfGraph(values: history.values, color: color, dimmed: true)
                        .frame(height: tileHeight)
                }
            }
        }
    }
}
