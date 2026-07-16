// Renders the 1200x630 social preview card used for Open Graph, Twitter and the
// GitHub repo's social image. Run via: swiftc -O Tools/make-og-image.swift -o /tmp/mkog && /tmp/mkog <out.png>
//
// Deliberately text-first: link unfurls render small, so the headline has to carry it.
// Colours track WinTheme so the card, the icon and the app agree.

import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./og-image.png"
let W: CGFloat = 1200, H: CGFloat = 630

let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)

// Background: the app's dark chrome, not a generic gradient.
let bg = NSRect(x: 0, y: 0, width: W, height: H)
NSColor(srgbRed: 0.126, green: 0.126, blue: 0.126, alpha: 1).setFill()
bg.fill()

// The Performance tab's grid lattice, faint, as texture.
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.05).cgColor)
ctx.setLineWidth(1)
for i in stride(from: 0, through: Int(W), by: 40) {
    ctx.move(to: CGPoint(x: CGFloat(i), y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(i), y: H))
}
for i in stride(from: 0, through: Int(H), by: 40) {
    ctx.move(to: CGPoint(x: 0, y: CGFloat(i))); ctx.addLine(to: CGPoint(x: W, y: CGFloat(i)))
}
ctx.strokePath()

// A CPU trace across the lower third, bleeding off both edges.
let samples: [CGFloat] = [0.20, 0.26, 0.18, 0.34, 0.28, 0.22, 0.30, 0.88, 0.64, 0.46,
                          0.54, 0.40, 0.32, 0.36, 0.30, 0.44, 0.38]
let plot = NSRect(x: -20, y: 0, width: W + 40, height: 190)
func point(_ i: Int) -> CGPoint {
    CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(samples.count - 1),
            y: plot.minY + plot.height * samples[i])
}
let area = NSBezierPath()
area.move(to: CGPoint(x: plot.minX, y: 0))
for i in samples.indices { area.line(to: point(i)) }
area.line(to: CGPoint(x: plot.maxX, y: 0))
area.close()
NSColor(srgbRed: 0.0, green: 0.47, blue: 0.83, alpha: 0.30).setFill()
area.fill()

let line = NSBezierPath()
line.move(to: point(0))
for i in samples.indices.dropFirst() { line.line(to: point(i)) }
line.lineWidth = 3
line.lineCapStyle = .round
line.lineJoinStyle = .round
NSColor(srgbRed: 0.30, green: 0.76, blue: 1.0, alpha: 1).setStroke()
line.stroke()

// Icon. Text draws upward from its baseline point, so the title's box reaches
// ~81pt above y — the icon has to clear that or it lands on the capitals.
if let icon = NSImage(contentsOfFile: "./assets/icon.png") ?? NSImage(contentsOfFile: "./docs/icon.png") {
    icon.draw(in: NSRect(x: 80, y: H - 62 - 128, width: 128, height: 128))
}

func draw(_ text: String, _ font: NSFont, _ color: NSColor, at p: NSPoint) {
    text.draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

draw("Task Manager for Mac",
     .systemFont(ofSize: 68, weight: .bold), .white,
     at: NSPoint(x: 80, y: H - 312))

draw("The Windows 11 Task Manager, on your Mac.",
     .systemFont(ofSize: 34, weight: .regular),
     NSColor(srgbRed: 0.30, green: 0.76, blue: 1.0, alpha: 1),
     at: NSPoint(x: 80, y: H - 370))

draw("All seven tabs · Live graphs · The heatmap · Native Swift · No dependencies",
     .systemFont(ofSize: 24, weight: .regular),
     NSColor(white: 0.72, alpha: 1),
     at: NSPoint(x: 80, y: H - 418))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { exit(1) }
try? png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
