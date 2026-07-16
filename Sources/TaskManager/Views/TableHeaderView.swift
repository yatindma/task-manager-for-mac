import SwiftUI

// MARK: - Column description

/// One column of a Windows-style table header.
///
/// `subtitle` + `heat` reproduce the Processes tab, where each heated heading
/// carries the system-wide total ("CPU" over "14%") and is tinted by that total.
/// Tabs without heat pass nil for both.
struct TableColumnSpec: Identifiable {
    let id: String
    let title: String
    /// nil means the column flexes to fill the remaining width.
    let defaultWidth: CGFloat?
    let alignment: Alignment
    let subtitle: String?
    /// 0...1 load driving the heading tint, nil for a flat heading.
    let heat: Double?
    let canHide: Bool

    init(
        id: String,
        title: String,
        defaultWidth: CGFloat?,
        alignment: Alignment = .trailing,
        subtitle: String? = nil,
        heat: Double? = nil,
        canHide: Bool = true
    ) {
        self.id = id
        self.title = title
        self.defaultWidth = defaultWidth
        self.alignment = alignment
        self.subtitle = subtitle
        self.heat = heat
        self.canHide = canHide
    }
}

// MARK: - Persisted column layout

/// Column widths and visibility for one table, persisted across launches.
/// Rows read the same store as the header so cells stay aligned.
@MainActor
/// Wraps a table so it scrolls horizontally once its columns stop fitting.
///
/// Every table here is an HStack of fixed-width columns, which cannot shrink. Placed
/// directly in the root HStack, its intrinsic width (932pt for Processes, against a
/// 1024pt window minus a 200pt sidebar) wins the layout negotiation and pushes the
/// sidebar off the left edge instead of clipping — the whole frame slides and both
/// sides get cut. Scrolling gives the table a floor of zero so the sidebar always
/// keeps its width, and matches Windows, which scrolls when columns do not fit.
struct TableScroller<Content: View>: View {
    let minimumWidth: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                content()
                    .frame(
                        width: max(geo.size.width, minimumWidth),
                        height: geo.size.height,
                        alignment: .leading
                    )
            }
        }
    }
}

final class TableColumnState: ObservableObject {
    /// Gap between cells; the header paints its divider inside it.
    static let dividerWidth: CGFloat = 1
    static let minColumnWidth: CGFloat = 48

    private let tableID: String
    private let defaults = UserDefaults.standard

    @Published private var widthOverrides: [String: CGFloat]
    @Published private var hidden: Set<String>

    init(tableID: String) {
        self.tableID = tableID
        let stored = defaults.dictionary(forKey: "table.\(tableID).widths") as? [String: Double] ?? [:]
        self.widthOverrides = stored.mapValues { CGFloat($0) }
        self.hidden = Set(defaults.stringArray(forKey: "table.\(tableID).hidden") ?? [])
    }

    /// Resolved width, or nil when the column still flexes.
    func width(_ spec: TableColumnSpec) -> CGFloat? {
        widthOverrides[spec.id] ?? spec.defaultWidth
    }

    func setWidth(_ width: CGFloat, for spec: TableColumnSpec) {
        widthOverrides[spec.id] = max(width, Self.minColumnWidth)
        defaults.set(
            widthOverrides.mapValues { Double($0) },
            forKey: "table.\(tableID).widths"
        )
    }

    /// Width the visible columns need before the flexible one starts being squeezed.
    ///
    /// Without this the table's intrinsic width (932pt for Processes) exceeds the
    /// window, and the surrounding HStack pushes the sidebar off the left edge
    /// instead of clipping. Callers scroll horizontally past this width, as Windows
    /// does when columns do not fit.
    func minimumWidth(of specs: [TableColumnSpec], flexMinimum: CGFloat = 220) -> CGFloat {
        let visible = specs.filter(isVisible)
        let columns = visible.reduce(CGFloat.zero) { $0 + (width($1) ?? flexMinimum) }
        return columns + CGFloat(max(visible.count - 1, 0)) * Self.dividerWidth
    }

    func isVisible(_ spec: TableColumnSpec) -> Bool {
        !hidden.contains(spec.id)
    }

    func setVisible(_ visible: Bool, for spec: TableColumnSpec) {
        guard spec.canHide else { return }
        if visible { hidden.remove(spec.id) } else { hidden.insert(spec.id) }
        defaults.set(Array(hidden), forKey: "table.\(tableID).hidden")
    }

    func visibleColumns(_ specs: [TableColumnSpec]) -> [TableColumnSpec] {
        specs.filter(isVisible)
    }
}

// MARK: - Header

/// Sortable, resizable, hideable table header shared by Processes, Details,
/// Services and Startup.
struct TableHeaderView: View {
    let columns: [TableColumnSpec]
    let sortColumnID: String
    let direction: SortDirection
    let onSort: (String) -> Void

    @ObservedObject var state: TableColumnState
    @Environment(\.colorScheme) private var scheme

    /// Width captured when a divider drag begins, so the drag is absolute.
    @State private var dragBase: CGFloat?

    var body: some View {
        let visible = state.visibleColumns(columns)

        HStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, spec in
                cell(spec)
                if index < visible.count - 1 {
                    divider(for: spec)
                }
            }
        }
        .frame(height: WinTheme.Metrics.headerHeight)
        .background(WinTheme.Palette.header(scheme))
        .overlay(alignment: .bottom) {
            WinTheme.Palette.border(scheme).frame(height: 1)
        }
        .contextMenu { columnChecklist }
    }

    // MARK: Pieces

    @ViewBuilder
    private func cell(_ spec: TableColumnSpec) -> some View {
        let isActive = spec.id == sortColumnID

        HStack(spacing: 4) {
            if spec.alignment == .trailing { Spacer(minLength: 0) }

            VStack(alignment: spec.alignment == .trailing ? .trailing : .leading, spacing: 0) {
                Text(spec.title)
                    .font(WinTheme.Typography.columnHeader)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                if let subtitle = spec.subtitle {
                    Text(subtitle)
                        .font(WinTheme.Typography.statLabel)
                        .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                }
            }
            .lineLimit(1)

            if isActive {
                Image(systemName: direction.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(WinTheme.Palette.accent(scheme))
            }

            if spec.alignment != .trailing { Spacer(minLength: 0) }
        }
        .padding(.horizontal, WinTheme.Metrics.cellPadding)
        .frame(width: state.width(spec), alignment: spec.alignment)
        .frame(maxWidth: state.width(spec) == nil ? .infinity : nil, maxHeight: .infinity)
        .background(spec.heat.map { WinTheme.heat($0, scheme) } ?? .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSort(spec.id) }
    }

    /// Divider to the right of `spec`; dragging it resizes `spec`.
    private func divider(for spec: TableColumnSpec) -> some View {
        WinTheme.Palette.border(scheme)
            .frame(width: TableColumnState.dividerWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                // A 1pt line is far too small to aim at. Windows gives the divider a
                // wide invisible grab strip; 11pt matches how it feels there.
                Color.clear
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // highPriority so the drag wins outright rather than racing the
                    // scroll view and the row gestures underneath it.
                    //
                    // minimumDistance must not be 0: the strip is 11pt wide and sits
                    // over the header, so a zero-distance drag turns every click near a
                    // column edge into a resize — it writes a width on the first
                    // onChanged and persists it, and the sort tap underneath never
                    // fires. A pixel of travel separates "clicked" from "dragged".
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                // A flexible column has no measured width until it is
                                // dragged; anchor it at its current default instead.
                                let base = dragBase ?? state.width(spec) ?? 240
                                if dragBase == nil { dragBase = base }
                                state.setWidth(base + value.translation.width, for: spec)
                            }
                            .onEnded { _ in dragBase = nil }
                    )
            }
    }

    @ViewBuilder
    private var columnChecklist: some View {
        ForEach(columns) { spec in
            Toggle(
                spec.title,
                isOn: Binding(
                    get: { state.isVisible(spec) },
                    set: { state.setVisible($0, for: spec) }
                )
            )
            .disabled(!spec.canHide)
        }
    }
}
