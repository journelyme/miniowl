#!/usr/bin/env swift

// ─────────────────────────────────────────────────────────────────────
// make-icon.swift — render the miniowl app icon programmatically.
//
// 1:1 port of the website logo at apps/miniowl/public/logo.svg, scaled
// from a 64×64 viewBox to a 1024×1024 master PNG. Colors are pulled
// straight from the design system tokens (apps/miniowl design-system):
//   --color-gray-950 #0C0A09   — squircle background + pupils
//   --color-gray-50  #FAFAF9   — sclera + eye highlights
//   --color-accent   #D97706   — signature amber for the beak
//
// No gradients, no stars, no inner shadow. Threads-minimal — exactly
// what the website ships. Run via tools/make-icon.sh; this file just
// produces the master PNG (the wrapper handles resampling + iconutil).
// ─────────────────────────────────────────────────────────────────────

import AppKit
import CoreGraphics

// Render at the same 1024 master size the .icns pipeline expects.
// Geometry below is expressed against a 64-unit logical viewBox to
// match the SVG, then multiplied by `unit` for actual pixels.
let size: CGFloat = 1024
let unit: CGFloat = size / 64

// Design-system colors.
let bgColor      = CGColor(red:  12/255.0, green:  10/255.0, blue:  9/255.0, alpha: 1.0) // #0C0A09
let scleraColor  = CGColor(red: 250/255.0, green: 250/255.0, blue: 249/255.0, alpha: 1.0) // #FAFAF9
let pupilColor   = bgColor                                                                  // matches bg
let accentColor  = CGColor(red: 217/255.0, green: 119/255.0, blue:   6/255.0, alpha: 1.0) // #D97706

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("make-icon: no graphics context\n", stderr)
    exit(1)
}

// CG origin is bottom-left, SVG origin is top-left. This helper does
// the y-flip per the SVG → CG conversion: cgY = size - svgY.
func y(_ svgY: CGFloat) -> CGFloat { size - svgY * unit }
func x(_ svgX: CGFloat) -> CGFloat { svgX * unit }

// ─── Squircle background ────────────────────────────────────────────
// SVG uses rx=14 on a 64×64 rect → corner radius = 14 * unit.
// macOS app-icon spec radius is 22.37%; 14/64 = 21.875% — close
// enough that the icon still sits comfortably inside the macOS mask.
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = 14 * unit
let bgPath = CGPath(
    roundedRect: bgRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

ctx.addPath(bgPath)
ctx.setFillColor(bgColor)
ctx.fillPath()

// ─── Eyes ───────────────────────────────────────────────────────────
// Direct port of:
//   <circle cx="22" cy="28" r="9" fill="#FAFAF9"/>   // outer / sclera
//   <circle cx="22" cy="28" r="5" fill="#0C0A09"/>   // pupil
//   <circle cx="24" cy="26" r="1.6" fill="#FAFAF9"/> // highlight
// Mirrored on cx=42 for the right eye.
func drawEye(svgCX: CGFloat, svgCY: CGFloat, highlightDX: CGFloat, highlightDY: CGFloat) {
    let cx = x(svgCX)
    let cy = y(svgCY)
    let scleraR: CGFloat = 9 * unit
    let pupilR:  CGFloat = 5 * unit
    let highR:   CGFloat = 1.6 * unit

    // Sclera
    ctx.setFillColor(scleraColor)
    ctx.fillEllipse(in: CGRect(x: cx - scleraR, y: cy - scleraR, width: scleraR * 2, height: scleraR * 2))

    // Pupil
    ctx.setFillColor(pupilColor)
    ctx.fillEllipse(in: CGRect(x: cx - pupilR, y: cy - pupilR, width: pupilR * 2, height: pupilR * 2))

    // Highlight (small white dot, offset toward upper-outside of pupil)
    let hx = x(svgCX + highlightDX)
    let hy = y(svgCY + highlightDY)
    ctx.setFillColor(scleraColor)
    ctx.fillEllipse(in: CGRect(x: hx - highR, y: hy - highR, width: highR * 2, height: highR * 2))
}

// SVG highlight offsets:
//   left eye:  (24, 26) vs (22, 28) → +2x, -2y
//   right eye: (44, 26) vs (42, 28) → +2x, -2y
drawEye(svgCX: 22, svgCY: 28, highlightDX: 2, highlightDY: -2)
drawEye(svgCX: 42, svgCY: 28, highlightDX: 2, highlightDY: -2)

// ─── Beak ───────────────────────────────────────────────────────────
// Direct port of:
//   <path d="M32 39 L28 45 L36 45 Z" fill="#D97706"/>
// Triangle apex at (32, 39), base from (28, 45) to (36, 45).
let beakPath = CGMutablePath()
beakPath.move(to:    CGPoint(x: x(32), y: y(39)))
beakPath.addLine(to: CGPoint(x: x(28), y: y(45)))
beakPath.addLine(to: CGPoint(x: x(36), y: y(45)))
beakPath.closeSubpath()

ctx.addPath(beakPath)
ctx.setFillColor(accentColor)
ctx.fillPath()

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
