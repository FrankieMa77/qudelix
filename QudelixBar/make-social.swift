#!/usr/bin/env swift
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640
let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .deletingLastPathComponent()
    .appendingPathComponent("docs/social-preview.png")
let shotURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .deletingLastPathComponent()
    .appendingPathComponent("docs/screenshots/equalizer.png")

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.15, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1),
])?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

ctx.saveGState()
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.55, blue: 0.95, alpha: 0.34),
    NSColor(calibratedRed: 0.18, green: 0.55, blue: 0.95, alpha: 0.0),
])
glow?.draw(in: NSRect(x: -W * 0.35, y: -H * 0.6, width: W * 1.9, height: H * 2.2),
           relativeCenterPosition: NSPoint(x: 0.30, y: 0.0))
ctx.restoreGState()

func curveY(_ t: CGFloat) -> CGFloat {
    let a = sin(t * .pi * 1.15) * 46
    let b = sin(t * .pi * 3.1 + 1.2) * 20
    let c = -pow(max(0, t - 0.62) * 3.4, 2) * 26
    return H * 0.44 + a + b + c
}
let curve = NSBezierPath()
curve.move(to: NSPoint(x: 0, y: curveY(0)))
for i in stride(from: 0, through: 1.0, by: 0.004) {
    curve.line(to: NSPoint(x: CGFloat(i) * W, y: curveY(CGFloat(i))))
}
let fill = curve.copy() as! NSBezierPath
fill.line(to: NSPoint(x: W, y: 0)); fill.line(to: NSPoint(x: 0, y: 0)); fill.close()
ctx.saveGState()
fill.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.25, green: 0.6, blue: 1.0, alpha: 0.16),
    NSColor(calibratedRed: 0.25, green: 0.6, blue: 1.0, alpha: 0.0),
])?.draw(in: NSRect(x: 0, y: 0, width: W, height: H * 0.6), angle: -90)
ctx.restoreGState()
NSColor(calibratedRed: 0.35, green: 0.66, blue: 1.0, alpha: 0.5).setStroke()
curve.lineWidth = 2.5
curve.stroke()

let iconRect = NSRect(x: 84, y: H - 84 - 96, width: 96, height: 96)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 22, yRadius: 22)
NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.58, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.26, blue: 0.60, alpha: 1),
])?.draw(in: iconPath, angle: -90)
if let sym = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 52, weight: .medium)) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    let w: CGFloat = 54, h = w * (tinted.size.height / max(tinted.size.width, 1))
    tinted.draw(in: NSRect(x: iconRect.midX - w / 2, y: iconRect.midY - h / 2, width: w, height: h))
}

func draw(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight,
          _ color: NSColor, at p: NSPoint, tracking: CGFloat = 0) {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    if tracking != 0 { attrs[.kern] = tracking }
    s.draw(at: p, withAttributes: attrs)
}

draw("Qudelix for macOS", 62, .bold, .white, at: NSPoint(x: 84, y: H - 246))
draw("Configure the Qudelix 5K from your menu bar",
     27, .regular, NSColor(white: 1, alpha: 0.72), at: NSPoint(x: 86, y: H - 296))

let bullets = [
    "Parametric EQ with a live response curve",
    "20 presets · AutoEq import for 6,000+ headphones",
    "Native, no browser — free and open source",
]
for (i, b) in bullets.enumerated() {
    let y = H - 372 - CGFloat(i) * 39
    let dot = NSBezierPath(ovalIn: NSRect(x: 88, y: y + 8, width: 8, height: 8))
    NSColor(calibratedRed: 0.35, green: 0.66, blue: 1.0, alpha: 0.95).setFill()
    dot.fill()
    draw(b, 22, .medium, NSColor(white: 1, alpha: 0.82), at: NSPoint(x: 110, y: y))
}

draw("github.com/FrankieMa77/qudelix", 19, .medium,
     NSColor(white: 1, alpha: 0.42), at: NSPoint(x: 86, y: 52))

if let shot = NSImage(contentsOf: shotURL) {
    let targetH: CGFloat = 560
    let scale = targetH / shot.size.height
    let targetW = shot.size.width * scale
    let rect = NSRect(x: W - targetW - 76, y: (H - targetH) / 2, width: targetW, height: targetH)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 42,
                  color: NSColor.black.withAlphaComponent(0.62).cgColor)
    let clip = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
    NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
    clip.fill()
    ctx.restoreGState()

    ctx.saveGState()
    clip.addClip()
    shot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()

    NSColor(white: 1, alpha: 0.13).setStroke()
    clip.lineWidth = 1.5
    clip.stroke()
}

NSGraphicsContext.restoreGraphicsState()

if let png = rep.representation(using: .png, properties: [:]) {
    try? FileManager.default.createDirectory(
        at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? png.write(to: outURL)
    print("wrote \(outURL.path) (\(Int(W))×\(Int(H)))")
}
