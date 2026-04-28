#!/usr/bin/env swift

// ─────────────────────────────────────────────────────────────────────
// make-dmg-bg.swift — render the DMG window background PNG.
//
// The DMG window shows two icons (miniowl.app on the left, the
// /Applications shortcut on the right). The background image guides
// the user with a headline and a subtle arrow between them — same
// pattern Raycast, Maccy, Linear, AltTab, etc. all use.
//
// Output: assets/dmg-background.png  (1120 × 800, retina-ready)
// At @2x, the DMG window itself displays at 560 × 400 logical px.
//
// Pure Core Graphics. No assets, no dependencies. Run via
// `swift tools/make-dmg-bg.swift` and check the result into git.
// ─────────────────────────────────────────────────────────────────────

import AppKit
import CoreGraphics

// Logical size = 560 × 400. Render at 2x for retina.
let scale: CGFloat = 2
let logicalW: CGFloat = 560
let logicalH: CGFloat = 400
let w = logicalW * scale
let h = logicalH * scale

let image = NSImage(size: NSSize(width: w, height: h))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("make-dmg-bg: no graphics context\n", stderr)
    exit(1)
}

// Design-system colors (apps/miniowl design-system tokens).
//   --color-gray-50  #FAFAF9 — page background
//   --color-gray-100 #F5F5F4 — subtle stop
//   --color-gray-950 #0C0A09 — primary text
//   --color-gray-500 #78716C — secondary / muted text
//   --color-accent   #D97706 — signature amber
let primaryText   = NSColor(red:  12/255.0, green:  10/255.0, blue:   9/255.0, alpha: 1.0) // #0C0A09
let mutedText     = NSColor(red: 120/255.0, green: 113/255.0, blue: 108/255.0, alpha: 1.0) // #78716C
let accentColor   = NSColor(red: 217/255.0, green: 119/255.0, blue:   6/255.0, alpha: 1.0) // #D97706
let pageBg        = CGColor(red: 250/255.0, green: 250/255.0, blue: 249/255.0, alpha: 1.0) // #FAFAF9
let pageBgStop    = CGColor(red: 245/255.0, green: 245/255.0, blue: 244/255.0, alpha: 1.0) // #F5F5F4

// ─── Background: subtle off-white gradient (gray-50 → gray-100) ─────
let bgRect = CGRect(x: 0, y: 0, width: w, height: h)
let bgGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [pageBg, pageBgStop] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGrad,
    start: CGPoint(x: w / 2, y: h),
    end: CGPoint(x: w / 2, y: 0),
    options: []
)

// ─── Headline at top: "Drag Miniowl to Applications" ────────────────
let headlineFontSize: CGFloat = 22 * scale
let headlineParagraph = NSMutableParagraphStyle()
headlineParagraph.alignment = .center
let headlineAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: headlineFontSize, weight: .semibold),
    .foregroundColor: primaryText,
    .paragraphStyle: headlineParagraph,
    .kern: 0.2,
]
let headline = NSAttributedString(string: "Drag Miniowl to Applications", attributes: headlineAttrs)
let headlineRect = CGRect(x: 0, y: h - 70 * scale, width: w, height: 32 * scale)
headline.draw(in: headlineRect)

// ─── Sub-headline: tiny instructions ────────────────────────────────
let subFontSize: CGFloat = 13 * scale
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: subFontSize, weight: .regular),
    .foregroundColor: mutedText,
    .paragraphStyle: headlineParagraph,
]
let sub = NSAttributedString(
    string: "Drop the icon on the right shortcut, then eject this window.",
    attributes: subAttrs
)
sub.draw(in: CGRect(x: 0, y: h - 100 * scale, width: w, height: 20 * scale))

// ─── Arrow between the two icon slots ───────────────────────────────
//
// The DMG window uses 128 × 128 icons. We position miniowl.app at
// (160, 200) logical and Applications at (400, 200) logical; the
// arrow runs between them at the same Y, just below center.
//
// Coords below are in flipped-from-bottom Core Graphics space, so
// the icon-row Y becomes (logicalH - 200) = 200 → 200 * scale.
let iconRowY = (logicalH - 200) * scale  // CG y; matches DS icon Y in osascript
let arrowY = iconRowY - 12 * scale        // slightly below icon centerline
let arrowStartX = (160 + 80) * scale       // right edge of left icon
let arrowEndX = (400 - 80) * scale         // left edge of right icon

// Arrow uses the signature amber at moderate opacity — design-system
// accent (#D97706) feels owl-y and ties the bg to the brand. Lower
// alpha so it stays subtle behind the icons, not garish.
let arrowColor = accentColor.withAlphaComponent(0.65).cgColor
ctx.setStrokeColor(arrowColor)
ctx.setLineWidth(2.5 * scale)
ctx.setLineCap(.round)

// Dashed shaft
ctx.setLineDash(phase: 0, lengths: [8 * scale, 6 * scale])
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 14 * scale, y: arrowY))
ctx.strokePath()

// Solid arrowhead
ctx.setLineDash(phase: 0, lengths: [])
let headSize: CGFloat = 14 * scale
let headTipX = arrowEndX
ctx.move(to: CGPoint(x: headTipX - headSize, y: arrowY + headSize * 0.55))
ctx.addLine(to: CGPoint(x: headTipX, y: arrowY))
ctx.addLine(to: CGPoint(x: headTipX - headSize, y: arrowY - headSize * 0.55))
ctx.strokePath()

// ─── Tiny "miniowl.me" credit at bottom ─────────────────────────────
let creditFontSize: CGFloat = 10 * scale
let creditAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: creditFontSize, weight: .medium),
    .foregroundColor: mutedText.withAlphaComponent(0.7),
    .paragraphStyle: headlineParagraph,
    .kern: 0.4,
]
let credit = NSAttributedString(string: "miniowl.me", attributes: creditAttrs)
credit.draw(in: CGRect(x: 0, y: 16 * scale, width: w, height: 16 * scale))

image.unlockFocus()

// ─── Write PNG ──────────────────────────────────────────────────────
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("make-dmg-bg: failed to encode PNG\n", stderr)
    exit(1)
}

let outDir = "assets"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outPath = "\(outDir)/dmg-background.png"
try? png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(Int(w)) × \(Int(h)) px, @2x of \(Int(logicalW)) × \(Int(logicalH)))")
