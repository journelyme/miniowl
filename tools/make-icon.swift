#!/usr/bin/env swift

// ─────────────────────────────────────────────────────────────────────
// make-icon.swift — draw the miniowl app icon programmatically.
//
// Run via tools/make-icon.sh — this file just renders the master 1024px
// PNG; the wrapper script handles all the resampling + iconutil work.
//
// The icon is a stylized owl face on a deep-night gradient: a large
// squircle background with two big round "eyes" and a tiny triangular
// beak. Pure Core Graphics, no assets, no dependencies.
// ─────────────────────────────────────────────────────────────────────

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("make-icon: no graphics context\n", stderr)
    exit(1)
}

// ─── Background: macOS-style squircle with night-sky gradient ────────
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = size * 0.2237  // matches macOS app icon spec
let bgPath = CGPath(
    roundedRect: rect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let gradColors = [
    CGColor(red: 0.07, green: 0.10, blue: 0.18, alpha: 1.0),  // deep navy
    CGColor(red: 0.16, green: 0.22, blue: 0.34, alpha: 1.0),  // slate
    CGColor(red: 0.32, green: 0.38, blue: 0.52, alpha: 1.0),  // soft blue-grey
] as CFArray
let gradLocations: [CGFloat] = [0.0, 0.55, 1.0]
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: gradColors,
    locations: gradLocations
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// ─── Stars (tiny dots) for character ─────────────────────────────────
let starPositions: [(CGFloat, CGFloat, CGFloat)] = [
    (0.12, 0.78, 4),
    (0.22, 0.88, 2.5),
    (0.78, 0.85, 3),
    (0.88, 0.74, 2),
    (0.16, 0.62, 2),
    (0.86, 0.62, 3),
]
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
for (xRatio, yRatio, r) in starPositions {
    let cx = size * xRatio
    let cy = size * yRatio
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}

// ─── Owl eyes ────────────────────────────────────────────────────────
// Two big round eyes side by side. White sclera, dark iris, white catchlight.
let eyeY: CGFloat = size * 0.46
let eyeR: CGFloat = size * 0.20
let eyeDX: CGFloat = size * 0.215  // half the gap between eye centers

func drawEye(centerX cx: CGFloat) {
    // White sclera with subtle glow rim
    let scleraRect = CGRect(x: cx - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
    ctx.fillEllipse(in: scleraRect)

    // Iris
    let irisR = eyeR * 0.62
    let irisRect = CGRect(x: cx - irisR, y: eyeY - irisR, width: irisR * 2, height: irisR * 2)
    let irisColors = [
        CGColor(red: 0.13, green: 0.18, blue: 0.27, alpha: 1.0),
        CGColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1.0),
    ] as CFArray
    let irisGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: irisColors,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addEllipse(in: irisRect)
    ctx.clip()
    ctx.drawRadialGradient(
        irisGrad,
        startCenter: CGPoint(x: cx, y: eyeY + irisR * 0.3),
        startRadius: 0,
        endCenter: CGPoint(x: cx, y: eyeY),
        endRadius: irisR,
        options: []
    )
    ctx.restoreGState()

    // Catchlight (small white highlight)
    let chR = eyeR * 0.13
    let chRect = CGRect(
        x: cx - chR + eyeR * 0.18,
        y: eyeY - chR + eyeR * 0.22,
        width: chR * 2,
        height: chR * 2
    )
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: chRect)

    // Smaller secondary catchlight
    let ch2R = eyeR * 0.06
    let ch2Rect = CGRect(
        x: cx - ch2R - eyeR * 0.05,
        y: eyeY - ch2R + eyeR * 0.05,
        width: ch2R * 2,
        height: ch2R * 2
    )
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.7))
    ctx.fillEllipse(in: ch2Rect)
}

drawEye(centerX: size * 0.5 - eyeDX)
drawEye(centerX: size * 0.5 + eyeDX)

// ─── Beak (small triangle below the eyes) ────────────────────────────
let beakTop = eyeY - eyeR * 0.95
let beakBottom = beakTop - size * 0.10
let beakHalfWidth = size * 0.045
let beakPath = CGMutablePath()
beakPath.move(to: CGPoint(x: size * 0.5, y: beakBottom))
beakPath.addLine(to: CGPoint(x: size * 0.5 - beakHalfWidth, y: beakTop))
beakPath.addLine(to: CGPoint(x: size * 0.5 + beakHalfWidth, y: beakTop))
beakPath.closeSubpath()

ctx.addPath(beakPath)
ctx.setFillColor(CGColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1.0))
ctx.fillPath()

ctx.restoreGState()

// ─── Subtle inner shadow on the squircle edge for depth ──────────────
ctx.saveGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

image.unlockFocus()

// ─── Export to PNG ───────────────────────────────────────────────────
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("make-icon: failed to encode PNG\n", stderr)
    exit(1)
}

let outURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/icon-1024.png")
try png.write(to: outURL)
print("wrote \(outURL.path) (\(png.count) bytes)")
