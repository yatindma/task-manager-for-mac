import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted by File ▸ Run new task; the command bar owns the sheet.
    static let runNewTaskRequested = Notification.Name("TaskManager.runNewTaskRequested")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var window: NSWindow!
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        buildWindow()

        AppState.shared.$alwaysOnTop
            .sink { [weak self] onTop in
                self?.window.level = onTop ? .floating : .normal
            }
            .store(in: &cancellables)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SystemMonitor.shared.stop()
    }

    // MARK: - Window

    private func buildWindow() {
        // Windows 11 Task Manager opens at 1024x700.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Task Manager"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Deliberately NOT movableByWindowBackground: it makes AppKit claim drags that
        // start anywhere over the content, which steals every column-divider drag in
        // the table headers and moves the window instead of resizing the column. The
        // transparent titlebar still drags the window normally.
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 640, height: 400)
        window.contentView = NSHostingView(rootView: RootView())
        window.setFrameAutosaveName("TaskManagerMainWindow")
        window.center()
        window.setFrameUsingName("TaskManagerMainWindow")
        window.level = AppState.shared.alwaysOnTop ? .floating : .normal
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    // MARK: - Menus

    private func buildMenus() {
        let main = NSMenu()

        // App
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Task Manager", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Task Manager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Task Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Run new task…", action: #selector(runNewTask), keyEquivalent: "n")
        let endTask = fileMenu.addItem(withTitle: "End task", action: #selector(endTask), keyEquivalent: "\u{8}")
        endTask.keyEquivalentModifierMask = []
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // View
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let refresh = viewMenu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: String(format: "%C", 0xF708))
        refresh.keyEquivalentModifierMask = []
        viewMenu.addItem(.separator())
        let speed = NSMenuItem(title: "Update speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu(title: "Update speed")
        for option in UpdateSpeed.allCases {
            let item = speedMenu.addItem(withTitle: option.title, action: #selector(setUpdateSpeed(_:)), keyEquivalent: "")
            item.representedObject = option
        }
        speed.submenu = speedMenu
        viewMenu.addItem(speed)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Window
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // Help
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Task Manager Help", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(endTask):
            return AppState.shared.selectedPID != nil
        case #selector(setUpdateSpeed(_:)):
            let speed = item.representedObject as? UpdateSpeed
            item.state = speed == UpdateSpeed.current ? .on : .off
            return true
        case #selector(toggleAlwaysOnTop):
            item.state = AppState.shared.alwaysOnTop ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - Actions

    @objc private func runNewTask() {
        NotificationCenter.default.post(name: .runNewTaskRequested, object: nil)
    }

    @objc private func endTask() {
        guard let pid = AppState.shared.selectedPID else { return }
        TaskCommands.endTask(pid: pid, in: window)
    }

    @objc private func refreshNow() {
        SystemMonitor.shared.refreshNow()
    }

    @objc private func setUpdateSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? UpdateSpeed else { return }
        AppDelegate.apply(speed)
    }

    /// Shared by the View menu and Settings' radio group so both stay in
    /// agreement with each other and with the persisted state.
    @MainActor
    static func apply(_ speed: UpdateSpeed) {
        AppState.shared.isPaused = (speed == .paused)
        if let interval = speed.interval {
            AppState.shared.updateInterval = interval
        }
        SystemMonitor.shared.start(interval: AppState.shared.updateInterval)
    }

    @objc private func toggleSidebar() {
        AppState.shared.sidebarExpanded.toggle()
    }

    @objc private func toggleAlwaysOnTop() {
        AppState.shared.alwaysOnTop.toggle()
    }

    @objc private func openSettings() {
        RootView.settingsRequested.send()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Task Manager"
        alert.informativeText = """
        Select a process and use File ▸ End task to terminate it.
        Press F5 to refresh immediately, or set View ▸ Update speed.
        """
        alert.runModal()
    }
}

/// The four rates the Windows Task Manager offers in View ▸ Update speed.
enum UpdateSpeed: CaseIterable, Equatable {
    case high, normal, low, paused

    var title: String {
        switch self {
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        case .paused: return "Paused"
        }
    }

    /// nil for `.paused`: there is no interval, sampling stops entirely.
    var interval: TimeInterval? {
        switch self {
        case .high: return 0.5
        case .normal: return 1.0
        case .low: return 2.0
        case .paused: return nil
        }
    }

    /// The speed that matches the app's current persisted state.
    @MainActor
    static var current: UpdateSpeed {
        if AppState.shared.isPaused { return .paused }
        return allCases.first { $0.interval == AppState.shared.updateInterval } ?? .normal
    }
}
