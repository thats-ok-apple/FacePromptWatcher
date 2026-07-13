import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: render_icon <output.png>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: .alphaFirst,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create icon bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
defer { NSGraphicsContext.restoreGraphicsState() }

let canvas = NSRect(origin: .zero, size: size)
let background = NSBezierPath(roundedRect: canvas, xRadius: 228, yRadius: 228)
NSGradient(
    colors: [
        NSColor(calibratedRed: 0.08, green: 0.60, blue: 0.72, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.59, alpha: 1),
    ]
)?.draw(in: background, angle: 70)

let glassRect = canvas.insetBy(dx: 108, dy: 108)
let glass = NSBezierPath(roundedRect: glassRect, xRadius: 166, yRadius: 166)
NSColor.white.withAlphaComponent(0.16).setFill()
glass.fill()
NSColor.white.withAlphaComponent(0.48).setStroke()
glass.lineWidth = 6
glass.stroke()

let glint = NSBezierPath(roundedRect: NSRect(x: 180, y: 684, width: 664, height: 118), xRadius: 59, yRadius: 59)
NSColor.white.withAlphaComponent(0.18).setFill()
glint.fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let title = NSAttributedString(
    string: "Face",
    attributes: [
        .font: NSFont.systemFont(ofSize: 236, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ]
)
title.draw(in: NSRect(x: 80, y: 396, width: 864, height: 270))

let subtitle = NSAttributedString(
    string: "PROMPT WATCHER",
    attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 42, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.74),
        .paragraphStyle: paragraph,
    ]
)
subtitle.draw(in: NSRect(x: 80, y: 304, width: 864, height: 60))

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon PNG\n", stderr)
    exit(1)
}

try png.write(to: outputURL)
