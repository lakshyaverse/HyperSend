#!/usr/bin/env swift
// Renders the DMG installer background (mac/dmg-bg.png, 1280x800).
//
//   xcrun swift tools/make-dmg-bg.swift mac/dmg-bg.png
//
// Layout is coordinated with mac/make-dmg.sh: icons (110 px) sit at Finder
// positions {340,300} and {830,300}, so the shelf, the arrow and the captions
// are drawn to frame exactly those spots.

import AppKit

let W: CGFloat = 1280, H: CGFloat = 800
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mac/dmg-bg.png"

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)

// Sky — the app's own backdrop.
let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                     colors: [rgb(158, 212, 252), rgb(148, 199, 252), rgb(120, 181, 252),
                              rgb(107, 158, 250), rgb(99, 148, 250)] as CFArray,
                     locations: [0, 0.32, 0.62, 0.85, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: W / 2, y: H), end: CGPoint(x: W / 2, y: 0), options: [])

func bloom(_ r: Double, _ g: Double, _ b: Double, _ a: Double, _ rect: CGRect) {
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(r, g, b, a), rgb(r, g, b, 0)] as CFArray, locations: [0, 1])!
    let c = CGPoint(x: rect.midX, y: rect.midY)
    ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                           endCenter: c, endRadius: max(rect.width, rect.height) / 2, options: [])
}
bloom(255, 224, 153, 0.55, CGRect(x: 0, y: H * 0.56, width: W * 0.55, height: H * 0.42))
bloom(250, 184, 168, 0.45, CGRect(x: W * 0.55, y: H * 0.2, width: W * 0.45, height: H * 0.5))
bloom(219, 217, 255, 0.45, CGRect(x: 0, y: 0, width: W * 0.5, height: H * 0.55))

// Wordmark, top centre.
let ink = rgb(24, 40, 86)
let title = NSAttributedString(string: "HyperSend", attributes: [
    .font: NSFont.systemFont(ofSize: 56, weight: .bold),
    .foregroundColor: NSColor(cgColor: ink)!,
])
let titleSize = title.size()
title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: H - 150))

let sub = NSAttributedString(string: "Wi-Fi and the USB cable, bonded", attributes: [
    .font: NSFont.systemFont(ofSize: 24, weight: .medium),
    .foregroundColor: NSColor(cgColor: ink)!.withAlphaComponent(0.72),
])
let subSize = sub.size()
sub.draw(at: NSPoint(x: (W - subSize.width) / 2, y: H - 196))

// Shelf the two icons will sit on. AppKit y is bottom-up; Finder icon row
// 300-410 (top-left) maps to AppKit 390-500.
let shelf = NSBezierPath(roundedRect: NSRect(x: 300, y: 348, width: 680, height: 200),
                         xRadius: 26, yRadius: 26)
NSColor(white: 1, alpha: 0.34).setFill()
shelf.fill()
NSColor(white: 1, alpha: 0.6).setStroke()
shelf.lineWidth = 1.5
shelf.stroke()

// Arrow from the app to Applications.
let arrowY: CGFloat = 445
let line = NSBezierPath()
line.lineWidth = 10
line.lineCapStyle = .round
line.move(to: NSPoint(x: 480, y: arrowY))
line.line(to: NSPoint(x: 782, y: arrowY))
NSColor(white: 1, alpha: 0.92).setStroke()
line.stroke()
let head = NSBezierPath()
head.lineWidth = 10
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: NSPoint(x: 752, y: arrowY + 30))
head.line(to: NSPoint(x: 786, y: arrowY))
head.line(to: NSPoint(x: 752, y: arrowY - 30))
head.stroke()

// Caption under the shelf.
let caption = NSAttributedString(string: "Drag to Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: NSColor(cgColor: ink)!.withAlphaComponent(0.85),
])
let captionSize = caption.size()
caption.draw(at: NSPoint(x: (W - captionSize.width) / 2, y: 282))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
