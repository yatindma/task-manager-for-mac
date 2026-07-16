import AppKit
import SwiftUI

/// Mirrors the Windows 11 Task Manager Settings page.
struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @Environment(\.colorScheme) private var scheme

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(WinTheme.Typography.sectionTitle)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))

                SettingsSection(title: "General") {
                    SettingsRow(
                        symbol: "house",
                        title: "Default start page",
                        subtitle: "Choose the page Task Manager opens on."
                    ) {
                        Picker("", selection: $state.startPage) {
                            ForEach(Tab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    SettingsRow(
                        symbol: "circle.lefthalf.filled",
                        title: "App theme",
                        subtitle: "Choose light, dark, or follow your Mac's appearance."
                    ) {
                        Picker("", selection: $state.appearance) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    SettingsRow(
                        symbol: "pin",
                        title: "Always on top",
                        subtitle: "Keep the Task Manager window above other windows."
                    ) {
                        Toggle("", isOn: $state.alwaysOnTop)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                SettingsSection(title: "Real time update speed") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(UpdateSpeed.allCases, id: \.title) { speed in
                            RadioRow(
                                title: speed.title,
                                detail: detail(for: speed),
                                selected: speed == UpdateSpeed.current
                            ) {
                                AppDelegate.apply(speed)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                SettingsSection(title: "Window management") {
                    SettingsRow(
                        symbol: "macwindow",
                        title: "Window position",
                        subtitle: "Task Manager reopens at its last size and position."
                    ) {
                        Button("Reset") {
                            UserDefaults.standard.removeObject(
                                forKey: "NSWindow Frame TaskManagerMainWindow"
                            )
                            if let window = NSApp.windows.first {
                                window.setContentSize(NSSize(width: 1024, height: 700))
                                window.center()
                            }
                        }
                        .font(WinTheme.Typography.row)
                    }
                }

                SettingsSection(title: "About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Task Manager")
                            .font(WinTheme.Typography.rowEmphasis)
                            .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                        Text("Version \(Self.version)")
                            .font(WinTheme.Typography.row)
                            .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                        Text("A Windows 11 Task Manager for macOS.")
                            .font(WinTheme.Typography.row)
                            .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A SwiftPM executable ships no Info.plist, so fall back to a constant.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func detail(for speed: UpdateSpeed) -> String {
        guard let interval = speed.interval else { return "Updates are paused" }
        return String(format: "Updates every %.1f seconds", interval)
    }
}

// MARK: - Building blocks

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(WinTheme.Typography.rowEmphasis)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: WinTheme.Metrics.cardCornerRadius)
                    .fill(WinTheme.Palette.header(scheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: WinTheme.Metrics.cardCornerRadius)
                    .strokeBorder(WinTheme.Palette.border(scheme), lineWidth: 1)
            }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                Text(subtitle)
                    .font(WinTheme.Typography.statLabel)
                    .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
            }

            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 10)
    }
}

private struct RadioRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            selected
                                ? WinTheme.Palette.accent(scheme)
                                : WinTheme.Palette.textSecondary(scheme),
                            lineWidth: selected ? 4 : 1
                        )
                        .frame(width: 16, height: 16)
                }

                Text(title)
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textPrimary(scheme))

                Text(detail)
                    .font(WinTheme.Typography.statLabel)
                    .foregroundStyle(WinTheme.Palette.textSecondary(scheme))

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
