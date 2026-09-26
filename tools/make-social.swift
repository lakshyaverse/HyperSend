#!/usr/bin/env swift
// Generates the GitHub social preview (1200x630) from the app's own palette.
//
//   swift tools/make-social.swift assets/icon.png assets/social-preview.png
//
// Same pastel sky as the window's SceneBackdrop, the app icon on the right,
// the wordmark and one honest line on the left. Regenerate when the palette
// or the icon changes so the repo card never drifts from the product.

import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-social <icon.png> <out.png>\n".utf8))
    exit(2)
}
let iconPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

let W: CGFloat = 1200, H: CGFloat = 630
guard let icon = NSImage(contentsOfFile: iconPath) else {
    FileHandle.standardError.write(Data("cannot read \(iconPath)\n".utf8))
    exit(1)
}

let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Sky, the same stops as SceneBackdrop.
let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                     colors: [rgb(158, 212, 252), rgb(148, 199, 252), rgb(120, 181, 252), rgb(107, 158, 250), rgb(99, 148, 250)] as CFArray,
                     locations: [0, 0.32, 0.62, 0.85, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: W / 2, y: H), end: CGPoint(x: W / 2, y: 0), options: [])

// Warm blooms.
func bloom(_ r: Double, _ g: Double, _ b: Double, _ a: Double, _ rect: CGRect) {
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(r, g, b, a), rgb(r, g, b, 0)] as CFArray, locations: [0, 1])!
    let c = CGPoint(x: rect.midX, y: rect.midY)
    ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                           endCenter: c, endRadius: max(rect.width, rect.height) / 2, options: [])
}
bloom(255, 224, 153, 0.55, CGRect(x: 0, y: H * 0.56, width: W * 0.55, height: H * 0.42))
bloom(250, 184, 168, 0.45, CGRect(x: W * 0.55, y: H * 0.2, width: W * 0.45, height: H * 0.5))
bloom(219, 217, 255, 0.45, CGRect(x: 0, y: 0, width: W * 0.5, height: H * 0.55))

// Icon, with the glow the glass panels cast in the app.
let side: CGFloat = 340
let iconRect = CGRect(x: W - side - 130, y: (H - side) / 2, width: side, height: side)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 70, color: rgb(20, 45, 110, 0.45))
icon.draw(in: iconRect)
ctx.restoreGState()

// Wordmark.
let para = NSMutableParagraphStyle()
para.lineBreakMode = .byWordWrapping
let title = NSAttributedString(string: "HyperSend", attributes: [
    .font: NSFont.systemFont(ofSize: 92, weight: .bold),
    .foregroundColor: NSColor(white: 0.07, alpha: 1),
])
title.draw(at: NSPoint(x: 96, y: H * 0.47))

let sub = NSAttributedString(string: "Every lane at once. Wi-Fi and the USB cable,\nbonded, verified byte for byte.", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .medium),
    .foregroundColor: NSColor(white: 0.13, alpha: 0.85),
])
sub.draw(at: NSPoint(x: 98, y: H * 0.30))

// A small glass-ish chip naming the platforms.
let chip = NSAttributedString(string: "macOS  ⇄  Android", attributes: [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold),
    .foregroundColor: NSColor(white: 0.1, alpha: 0.9),
])
let chipSize = chip.size()
let chipRect = CGRect(x: 98, y: H * 0.17, width: chipSize.width + 44, height: chipSize.height + 22)
let chipPath = CGPath(roundedRect: chipRect, cornerWidth: chipRect.height / 2, cornerHeight: chipRect.height / 2, transform: nil)
ctx.addPath(chipPath)
ctx.setFillColor(rgb(255, 255, 255, 0.5))
ctx.fillPath()
ctx.addPath(chipPath)
ctx.setStrokeColor(rgb(255, 255, 255, 0.85))
ctx.setLineWidth(1.5)
ctx.strokePath()
chip.draw(at: NSPoint(x: chipRect.minX + 22, y: chipRect.minY + 10))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { exit(1) }
try? png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
