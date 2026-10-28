#!/usr/bin/env swift
import AppKit

// Vector artwork rendered at every macOS icon size; no external assets or dependencies.
let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("artifacts/MacMirror.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func render(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MacMirror.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0.02, 0.08, 0.22, 0.28)
    shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    color(0.03, 0.26, 0.76).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.04, 0.29, 0.84), ending: color(0.13, 0.65, 1))!.draw(in: tile, angle: 65)
    NSColor.white.withAlphaComponent(0.24).setStroke(); tile.lineWidth = 3; tile.stroke()

    // Two overlapping displays follow the symbol used in the application's title bar.
    let back = NSBezierPath(roundedRect: NSRect(x: 211, y: 401, width: 439, height: 318), xRadius: 45, yRadius: 45)
    back.lineWidth = 34; back.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.67).setStroke(); back.stroke()
    let frontRect = NSRect(x: 374, y: 281, width: 439, height: 318)
    let front = NSBezierPath(roundedRect: frontRect, xRadius: 45, yRadius: 45)
    NSGraphicsContext.saveGraphicsState()
    let screenShadow = NSShadow(); screenShadow.shadowColor = color(0.01, 0.08, 0.35, 0.30)
    screenShadow.shadowBlurRadius = 24; screenShadow.shadowOffset = NSSize(width: 0, height: -9); screenShadow.set()
    color(0.06, 0.36, 0.85).setFill(); front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.08, 0.38, 0.88), ending: color(0.13, 0.54, 0.96))!.draw(in: front, angle: 90)
    NSColor.white.setStroke(); front.lineWidth = 34; front.stroke()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "MacMirror.Icon", code: 2) }
    return png
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: directory.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: directory.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("Ícone: \(directory.path)")
