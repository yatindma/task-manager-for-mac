import SwiftUI

/// Windows 11 Task Manager visual language, with a light macOS accent.
///
/// Layout, metrics and the heatmap are matched to Windows. Typography uses SF Pro
/// and chrome uses native vibrancy, so the app still reads as a Mac app.
enum WinTheme {

    // MARK: - Palette

    /// A colour that resolves differently in light and dark appearance.
    struct Duo {
        let light: Color
        let dark: Color

        func callAsFunction(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? dark : light
        }
    }

    enum Palette {
        /// Window background behind the sidebar (sits on top of vibrancy).
        static let mica = Duo(light: Color(hex: 0xF3F3F3), dark: Color(hex: 0x202020))
        /// Background of the content card to the right of the sidebar.
        static let card = Duo(light: Color(hex: 0xFBFBFB), dark: Color(hex: 0x2C2C2C))
        /// Hairline borders around cards and between table columns.
        static let border = Duo(light: Color(hex: 0xE5E5E5), dark: Color(hex: 0x3A3A3A))
        /// Table header background.
        static let header = Duo(light: Color(hex: 0xF9F9F9), dark: Color(hex: 0x272727))

        static let textPrimary = Duo(light: Color(hex: 0x1B1B1B), dark: Color(hex: 0xFFFFFF))
        static let textSecondary = Duo(light: Color(hex: 0x5D5D5D), dark: Color(hex: 0xC5C5C5))

        /// Windows accent blue. Dark mode uses the lighter Fluent variant.
        static let accent = Duo(light: Color(hex: 0x0078D4), dark: Color(hex: 0x4CC2FF))
        static let rowHover = Duo(light: Color(hex: 0xF0F0F0), dark: Color(hex: 0x383838))
        static let rowSelected = Duo(light: Color(hex: 0xE1EFFA), dark: Color(hex: 0x33404A))
        static let gridLine = Duo(light: Color(hex: 0xD6D6D6), dark: Color(hex: 0x3F3F3F))
    }

    /// Per-metric graph colours used on the Performance tab.
    enum Graph {
        static let cpu = Duo(light: Color(hex: 0x0078D4), dark: Color(hex: 0x4CC2FF))
        static let memory = Duo(light: Color(hex: 0x8764B8), dark: Color(hex: 0xB393E0))
        static let disk = Duo(light: Color(hex: 0x107C10), dark: Color(hex: 0x4CD964))
        static let network = Duo(light: Color(hex: 0x0078D4), dark: Color(hex: 0x4CC2FF))
        static let gpu = Duo(light: Color(hex: 0x0078D4), dark: Color(hex: 0x4CC2FF))
        /// Opacity of the filled area under a graph line.
        static let fillOpacity: Double = 0.25
    }

    // MARK: - Heatmap

    /// Windows tints a table cell yellow → orange → red as its load rises.
    /// `load` is 0...1; 0 returns clear so idle rows stay flat.
    static func heat(_ load: Double, _ scheme: ColorScheme) -> Color {
        let t = min(max(load, 0), 1)
        guard t > 0.001 else { return .clear }

        let stops: [(Double, UInt32)] = scheme == .dark
            ? [(0.0, 0x3A3620), (0.35, 0x4D4526), (0.7, 0x5C3A2A), (1.0, 0x6B2C2C)]
            : [(0.0, 0xFEFBE8), (0.35, 0xFCF3CF), (0.7, 0xFAD7A0), (1.0, 0xF1948A)]

        for i in 0..<(stops.count - 1) {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            if t <= t1 {
                let f = t1 == t0 ? 0 : (t - t0) / (t1 - t0)
                return Color(hex: c0).blended(to: Color(hex: c1), amount: f)
            }
        }
        return Color(hex: stops[stops.count - 1].1)
    }

    // MARK: - Metrics

    enum Metrics {
        static let rowHeight: CGFloat = 28
        static let headerHeight: CGFloat = 34
        static let sidebarExpandedWidth: CGFloat = 200
        static let sidebarCollapsedWidth: CGFloat = 48
        static let sidebarItemHeight: CGFloat = 36
        static let commandBarHeight: CGFloat = 48
        static let cardCornerRadius: CGFloat = 8
        static let cellPadding: CGFloat = 8
        static let indentPerLevel: CGFloat = 16
    }

    enum Typography {
        static let row = Font.system(size: 12)
        static let rowEmphasis = Font.system(size: 12, weight: .medium)
        static let columnHeader = Font.system(size: 12)
        static let sidebarItem = Font.system(size: 13)
        static let sectionTitle = Font.system(size: 20, weight: .semibold)
        static let statValue = Font.system(size: 28, weight: .light)
        static let statLabel = Font.system(size: 11)
        static let mono = Font.system(size: 12, design: .monospaced)
    }

    // MARK: - Formatting

    /// Windows-style byte sizes: "412.3 MB", "1.2 GB".
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(value, 0)
        var unit = 0
        while v >= 1024 && unit < units.count - 1 {
            v /= 1024
            unit += 1
        }
        let digits = (v < 10 && unit > 0) ? 1 : 0
        return String(format: "%.\(digits)f %@", v, units[unit])
    }

    /// Throughput as Windows shows it: "0 MB/s", "1.4 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "0 MB/s" : bytes(bytesPerSecond) + "/s"
    }

    /// Percentages as Windows shows them: "0%", "3.2%", "100%".
    static func percent(_ value: Double) -> String {
        if value <= 0 { return "0%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    /// Uptime as "d:hh:mm:ss", matching the Performance tab.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%d:%02d:%02d:%02d", days, hours, minutes, secs)
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Linear blend towards `other`. `amount` is 0...1.
    func blended(to other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let f = min(max(amount, 0), 1)
        return Color(
            .sRGB,
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * f),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * f),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * f),
            opacity: Double(a.alphaComponent + (b.alphaComponent - a.alphaComponent) * f)
        )
    }
}

/// Native macOS vibrancy behind the sidebar — the "slight Mac touch" on top of
/// the Windows layout, standing in for Mica.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
