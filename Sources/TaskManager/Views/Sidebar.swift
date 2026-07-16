import SwiftUI

/// Windows 11 Fluent NavigationView: hamburger, one row per tab, gear pinned low.
struct Sidebar: View {
    @Binding var showingSettings: Bool

    @ObservedObject private var state = AppState.shared
    @Environment(\.colorScheme) private var scheme

    init(showingSettings: Binding<Bool>) {
        self._showingSettings = showingSettings
    }

    private var width: CGFloat {
        state.sidebarExpanded
            ? WinTheme.Metrics.sidebarExpandedWidth
            : WinTheme.Metrics.sidebarCollapsedWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Clears the traffic lights, which float over the sidebar vibrancy.
            Color.clear.frame(height: 28)

            SidebarButton(
                symbol: "line.3.horizontal",
                label: "",
                tooltip: "Navigation",
                selected: false,
                expanded: state.sidebarExpanded
            ) {
                withAnimation(.easeOut(duration: 0.18)) {
                    state.sidebarExpanded.toggle()
                }
            }

            Spacer().frame(height: 6)

            ForEach(Tab.allCases) { tab in
                SidebarButton(
                    symbol: tab.symbol,
                    label: tab.rawValue,
                    tooltip: tab.rawValue,
                    selected: state.tab == tab && !showingSettings,
                    expanded: state.sidebarExpanded
                ) {
                    state.tab = tab
                    showingSettings = false
                }
            }

            Spacer(minLength: 0)

            SidebarButton(
                symbol: "gearshape",
                label: "Settings",
                tooltip: "Settings",
                selected: showingSettings,
                expanded: state.sidebarExpanded
            ) {
                showingSettings = true
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, WinTheme.Metrics.cellPadding)
        .frame(width: width, alignment: .leading)
        // Without this the content pane, which is wider than the window, wins the
        // HStack negotiation and squeezes the nav until its labels clip.
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
}

private struct SidebarButton: View {
    let symbol: String
    let label: String
    let tooltip: String
    let selected: Bool
    let expanded: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(background)

                // Fluent selection treatment: a 3pt accent bar on the leading edge.
                if selected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(WinTheme.Palette.accent(scheme))
                        .frame(width: 3, height: 16)
                        .padding(.leading, 3)
                }

                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .frame(width: 20)
                    if expanded && !label.isEmpty {
                        Text(label)
                            .font(WinTheme.Typography.sidebarItem)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
            }
            .frame(height: WinTheme.Metrics.sidebarItemHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "" : tooltip)
    }

    private var background: Color {
        if selected { return WinTheme.Palette.rowSelected(scheme) }
        if hovering { return WinTheme.Palette.rowHover(scheme) }
        return .clear
    }
}
