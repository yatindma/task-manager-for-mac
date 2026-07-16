// Renders Icon.icns from code — Xcode asset catalogs are not available to SwiftPM here.
// Run via Tools/make-icon.sh; it feeds the PNGs to iconutil.
//
// The mark: a Fluent-blue rounded square carrying the Task Manager pulse graph —
// a filled area chart with the grid lattice the Performance tab draws, so the icon
// and the app read as the same thing.

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Icon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

/// The Windows accent, lightened at the top so the tile has depth at 1024pt.
let top = NSColor(srgbRed: 0.24, green: 0.60, blue: 0.90, alpha: 1)
let bottom = NSColor(srgbRed: 0.00, green: 0.36, blue: 0.72, alpha: 1)

func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icons sit on a rounded square inset from the canvas, not edge to edge.
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237   // Big Sur squircle ratio
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    tile.addClip()
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

    // Grid lattice, matching PerfGraph's static grid.
    let cells = 6
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    ctx.setLineWidth(max(s * 0.004, 0.5))
    for i in 1..<cells {
        let f = CGFloat(i) / CGFloat(cells)
        ctx.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
    }
    ctx.strokePath()

    // The pulse: a CPU trace with a spike, the shape everyone recognises.
    //
    // The plot spans the full tile so the filled area bleeds off both edges and down
    // to the base, where the squircle clips it. Insetting it instead leaves the fill's
    // own rectangle visible — a hard box floating inside the tile.
    let samples: [CGFloat] = [0.18, 0.22, 0.16, 0.30, 0.24, 0.20, 0.86, 0.62, 0.44, 0.52, 0.38, 0.30, 0.34]
    let plot = NSRect(
        x: rect.minX,
        y: rect.minY + rect.height * 0.16,
        width: rect.width,
        height: rect.height * 0.56
    )
    func point(_ i: Int) -> CGPoint {
        let x = plot.minX + plot.width * CGFloat(i) / CGFloat(samples.count - 1)
        return CGPoint(x: x, y: plot.minY + plot.height * samples[i])
    }

    let area = NSBezierPath()
    area.move(to: CGPoint(x: plot.minX, y: rect.minY))
    for i in samples.indices { area.line(to: point(i)) }
    area.line(to: CGPoint(x: plot.maxX, y: rect.minY))
    area.close()
    NSColor.white.withAlphaComponent(0.26).setFill()
    area.fill()

    let line = NSBezierPath()
    line.move(to: point(0))
    for i in samples.indices.dropFirst() { line.line(to: point(i)) }
    line.lineWidth = max(s * 0.035, 1.2)
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    NSColor.white.setStroke()
    line.stroke()

    ctx.restoreGState()
    return image
}

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard pixels <= 1024 else { continue }
        let image = render(size: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { continue }
        let suffix = scale == 2 ? "@2x" : ""
        let path = "\(outputDir)/icon_\(size)x\(size)\(suffix).png"
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

print("iconset written to \(outputDir)")
