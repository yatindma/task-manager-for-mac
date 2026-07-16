import Combine
import SwiftUI

/// The Windows 11 two-pane frame: icon sidebar, command bar, page.
struct RootView: View {
    /// Lets the app menu open Settings, which is not a `Tab` case.
    static let settingsRequested = PassthroughSubject<Void, Never>()

    @ObservedObject private var state = AppState.shared
    @Environment(\.colorScheme) private var scheme

    /// Settings is a gear pinned below the nav, not one of the tabs, so it
    /// needs its own selection state rather than a `Tab` case.
    @State private var showingSettings = false

    init() {}

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(showingSettings: $showingSettings)

            VStack(spacing: 0) {
                CommandBar()
                content
            }
            .background(WinTheme.Palette.card(scheme))
            .clipShape(RoundedRectangle(cornerRadius: WinTheme.Metrics.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: WinTheme.Metrics.cardCornerRadius)
                    .strokeBorder(WinTheme.Palette.border(scheme), lineWidth: 1)
            )
            .padding(.trailing, WinTheme.Metrics.cellPadding)
            .padding(.vertical, WinTheme.Metrics.cellPadding)
        }
        .background {
            ZStack {
                VisualEffectBackground(material: .sidebar)
                WinTheme.Palette.mica(scheme).opacity(0.35)
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 640, minHeight: 400)
        .onReceive(RootView.settingsRequested) { _ in
            showingSettings = true
        }
        .onChange(of: state.tab) { _, _ in
            showingSettings = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if showingSettings {
            SettingsView()
        } else {
            switch state.tab {
            case .processes: ProcessesView()
            case .performance: PerformanceView()
            case .appHistory: AppHistoryView()
            case .startupApps: StartupView()
            case .users: UsersView()
            case .details: DetailsView()
            case .services: ServicesView()
            }
        }
    }
}
