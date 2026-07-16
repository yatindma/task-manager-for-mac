import AppKit
import Combine
import Foundation
import SwiftUI

/// Windows 11 Task Manager offers exactly these three under Settings > Appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "Use system setting"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    /// nil follows the system, which is what NSApp.appearance = nil means.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// UI state shared by every tab. Window preferences persist across launches.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    private enum Key {
        static let alwaysOnTop = "alwaysOnTop"
        static let startPage = "startPage"
        static let updateInterval = "updateInterval"
        static let appearance = "appearance"
        static let isPaused = "isPaused"
    }

    @Published var tab: Tab
    @Published var selectedPID: pid_t?
    @Published var searchText: String = ""
    @Published var sidebarExpanded: Bool = true

    /// The sampling cadence used whenever the monitor is actually running.
    /// Stays at the last non-paused speed while `isPaused` is true, so
    /// resuming picks up where the user left off and consumers that key
    /// graph animation cadence off this value keep a sane number.
    @Published var updateInterval: TimeInterval {
        didSet { defaults.set(updateInterval, forKey: Key.updateInterval) }
    }

    /// True means the sampler is fully stopped; only Refresh now / F5 samples.
    @Published var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Key.isPaused) }
    }

    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop) }
    }

    @Published var startPage: Tab {
        didSet { defaults.set(startPage.rawValue, forKey: Key.startPage) }
    }

    @Published var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedStart = defaults.string(forKey: Key.startPage).flatMap(Tab.init(rawValue:)) ?? .processes
        self.startPage = storedStart
        self.tab = storedStart
        self.alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        self.appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system

        let storedInterval = defaults.double(forKey: Key.updateInterval)
        // 0 means "never written"; anything else must be one of the running speeds.
        self.updateInterval = Self.validIntervals.contains(storedInterval) ? storedInterval : 1.0
        self.isPaused = defaults.bool(forKey: Key.isPaused)
    }

    /// Overrides the whole app, so SwiftUI's colorScheme environment and the AppKit
    /// vibrancy behind the sidebar stay in agreement — setting only .preferredColorScheme
    /// would leave the NSVisualEffectView following the system while the rest flipped.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// Normal, High, Low — the sampling cadences Windows offers. Paused is a
    /// separate `isPaused` flag, not a fourth interval: it stops sampling
    /// entirely rather than running one slowly.
    static let validIntervals: [TimeInterval] = [1.0, 0.5, 2.0]
}
