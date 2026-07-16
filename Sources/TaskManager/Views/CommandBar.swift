import AppKit
import SwiftUI

extension Notification.Name {
    /// The command bar's primary button for tabs whose selection is not PID-based.
    /// The owning tab view acts on its own selected row.
    static let primaryCommandInvoked = Notification.Name("TaskManager.primaryCommandInvoked")
}

/// AppState.selectedPID can't represent a Startup row (no PID at all) or a stopped
/// Service (pid is nil), so those two tabs publish their selection here instead.
/// The owning view sets these on selection; CommandBar reads them to enable/label
/// its primary button.
@MainActor
final class TabSelectionBridge: ObservableObject {
    static let shared = TabSelectionBridge()

    @Published var selectedStartupID: String?
    @Published var selectedServiceLabel: String?

    private init() {}
}

/// Shared entry points for the destructive commands, so the menu bar and the
/// command bar behave identically.
@MainActor
enum TaskCommands {
    /// SIGTERM first; if the process ignores it, offer SIGKILL the way Windows
    /// escalates to "End process tree".
    static func endTask(pid: pid_t, in window: NSWindow?) {
        let name = SystemMonitor.shared.processes
            .first { $0.pid == pid }?.displayName ?? "this process"

        if ProcessActions.endTask(pid) { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to end \(name)."
        alert.informativeText = "The process did not respond to a request to quit. Force quitting will discard unsaved data."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            if !ProcessActions.forceKill(pid) {
                presentFailure("Task Manager could not force quit \(name). It may require elevated privileges.")
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    static func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Task Manager"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct CommandBar: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var selectionBridge = TabSelectionBridge.shared
    @Environment(\.colorScheme) private var scheme

    @State private var showingNewTask = false

    init() {}

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingNewTask = true
            } label: {
                Label("Run new task", systemImage: "plus")
                    .font(WinTheme.Typography.row)
            }
            .buttonStyle(CommandButtonStyle())

            if let title = primaryTitle {
                Button(action: invokePrimary) {
                    Text(title)
                        .font(WinTheme.Typography.row)
                }
                .buttonStyle(CommandButtonStyle())
                .disabled(!primaryEnabled)
            }

            Spacer(minLength: 12)

            SearchField(text: $state.searchText)
                .frame(minWidth: 120, maxWidth: 260)
        }
        .padding(.horizontal, 12)
        .frame(height: WinTheme.Metrics.commandBarHeight)
        .background(WinTheme.Palette.header(scheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WinTheme.Palette.border(scheme))
                .frame(height: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .runNewTaskRequested)) { _ in
            showingNewTask = true
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskSheet()
        }
    }

    // MARK: - Primary command

    /// nil hides the button entirely — Performance has no per-row action, so Windows
    /// shows nothing there rather than a dead control.
    private var primaryTitle: String? {
        switch state.tab {
        case .processes, .details, .users:
            return "End task"
        case .startupApps:
            guard let id = selectionBridge.selectedStartupID,
                  let row = monitor.startupItems.first(where: { $0.id == id })
            else { return "Disable" }
            return row.status == "Enabled" ? "Disable" : "Enable"
        case .services:
            guard let label = selectionBridge.selectedServiceLabel,
                  let row = monitor.services.first(where: { $0.label == label })
            else { return "Start" }
            return row.status == "Running" ? "Stop" : "Start"
        case .appHistory:
            return "Delete usage history"
        case .performance:
            return nil
        }
    }

    /// App history clears everything, so it needs no selection; the rest act on a row.
    private var primaryEnabled: Bool {
        switch state.tab {
        case .appHistory: return true
        case .performance: return false
        case .startupApps: return selectionBridge.selectedStartupID != nil
        case .services: return selectionBridge.selectedServiceLabel != nil
        case .processes, .details, .users: return state.selectedPID != nil
        }
    }

    private func invokePrimary() {
        switch state.tab {
        case .processes, .details, .users:
            guard let pid = state.selectedPID else { return }
            TaskCommands.endTask(pid: pid, in: NSApp.keyWindow)
        case .startupApps, .services, .appHistory:
            NotificationCenter.default.post(name: .primaryCommandInvoked, object: state.tab)
        case .performance:
            break
        }
    }
}

// MARK: - Create new task

/// Mirrors the Windows "Create new task" dialog.
private struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var command = ""
    @State private var asAdmin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "app.badge")
                    .font(.system(size: 28))
                    .foregroundStyle(WinTheme.Palette.accent(scheme))
                Text("Type the name of a program, folder, document, or Internet resource, and Task Manager will open it for you.")
                    .font(WinTheme.Typography.row)
                    .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Open:")
                    .font(WinTheme.Typography.row)
                TextField("", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(WinTheme.Typography.row)
                    .onSubmit(create)
                Button("Browse…", action: browse)
                    .font(WinTheme.Typography.row)
            }

            Toggle("Create this task with administrative privileges.", isOn: $asAdmin)
                .font(WinTheme.Typography.row)
                .toggleStyle(.checkbox)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            command = url.path
        }
    }

    private func create() {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try ProcessActions.runNewTask(command: trimmed, asAdmin: asAdmin)
            dismiss()
        } catch {
            TaskCommands.presentFailure(
                "Task Manager cannot run \"\(trimmed)\". \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Chrome

private struct CommandButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                WinTheme.Palette.textPrimary(scheme).opacity(isEnabled ? 1 : 0.4)
            )
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        configuration.isPressed
                            ? WinTheme.Palette.rowSelected(scheme)
                            : (hovering && isEnabled ? WinTheme.Palette.rowHover(scheme) : WinTheme.Palette.card(scheme))
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(WinTheme.Palette.border(scheme), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct SearchField: View {
    @Binding var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))

            TextField("Type a name, publisher, or PID", text: $text)
                .textFieldStyle(.plain)
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(WinTheme.Palette.card(scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(WinTheme.Palette.border(scheme), lineWidth: 1)
        }
    }
}
