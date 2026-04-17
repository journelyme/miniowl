#!/usr/bin/env swift

// ─────────────────────────────────────────────────────────────────────
// make-menubar-icon.swift — draw the miniowl menu bar template icon.
//
// Produces a "template" PNG: owl eyes + beak in black on transparent.
// macOS renders template images in the correct color for the menu bar
// (dark text on light bar, white text on dark bar) automatically.
//
// Output: build/MenuBarIcon.png (18x18 @2x = 36x36 px)
//         build/MenuBarIcon-paused.png (eyes half-closed variant)
// ─────────────────────────────────────────────────────────────────────

import AppKit
import CoreGraphics

func drawMenuBarIcon(paused: Bool, size: CGFloat = 36) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        fputs("make-menubar-icon: no graphics context\n", stderr)
        exit(1)
    }

    // All drawing in black — macOS template rendering handles the rest.
    let black = CGColor(gray: 0, alpha: 1.0)

    // ─── Owl head outline (rounded squircle, subtle) ─────────────
    let headInset: CGFloat = size * 0.06
    let headRect = CGRect(
        x: headInset, y: headInset,
        width: size - headInset * 2, height: size - headInset * 2
    )
    let headCorner: CGFloat = size * 0.28
    let headPath = CGPath(
        roundedRect: headRect,
        cornerWidth: headCorner,
        cornerHeight: headCorner,
        transform: nil
    )
    ctx.setStrokeColor(black)
    ctx.setLineWidth(size * 0.06)
    ctx.addPath(headPath)
    ctx.strokePath()

    // ─── Eyes ─────────────────────────────────────────────────────
    let eyeY = size * 0.52
    let eyeRadius = size * 0.15
    let eyeSpacing = size * 0.22

    let leftEyeCenter = CGPoint(x: size / 2 - eyeSpacing, y: eyeY)
    let rightEyeCenter = CGPoint(x: size / 2 + eyeSpacing, y: eyeY)

    ctx.setFillColor(black)

    if paused {
        // Half-closed eyes (horizontal lines) for paused state
        ctx.setLineWidth(size * 0.07)
        ctx.setLineCap(.round)
        for center in [leftEyeCenter, rightEyeCenter] {
            ctx.move(to: CGPoint(x: center.x - eyeRadius * 0.8, y: center.y))
            ctx.addLine(to: CGPoint(x: center.x + eyeRadius * 0.8, y: center.y))
        }
        ctx.strokePath()
    } else {
        // Open eyes (filled circles)
        for center in [leftEyeCenter, rightEyeCenter] {
            let eyeRect = CGRect(
                x: center.x - eyeRadius,
                y: center.y - eyeRadius,
                width: eyeRadius * 2,
                height: eyeRadius * 2
            )
            ctx.fillEllipse(in: eyeRect)
        }
    }

    // ─── Beak (small downward triangle) ──────────────────────────
    let beakTop = size * 0.36
    let beakBottom = size * 0.24
    let beakHalfWidth = size * 0.06

    ctx.beginPath()
    ctx.move(to: CGPoint(x: size / 2, y: beakBottom))
    ctx.addLine(to: CGPoint(x: size / 2 - beakHalfWidth, y: beakTop))
    ctx.addLine(to: CGPoint(x: size / 2 + beakHalfWidth, y: beakTop))
    ctx.closePath()
    ctx.fillPath()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("make-menubar-icon: failed to encode PNG\n", stderr)
        exit(1)
    }
    let url = URL(fileURLWithPath: path)
    try! png.write(to: url)
    print("wrote: \(path) (\(png.count) bytes)")
}

// Ensure output directory
let fm = FileManager.default
try? fm.createDirectory(atPath: "build", withIntermediateDirectories: true)

// Generate both states at @2x (36px for 18pt menu bar icon)
let active = drawMenuBarIcon(paused: false)
let paused = drawMenuBarIcon(paused: true)

savePNG(active, to: "build/MenuBarIcon.png")
savePNG(paused, to: "build/MenuBarIcon-paused.png")

print("done — both icons generated")
