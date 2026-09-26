#!/usr/bin/env swift
//
// Generates HyperSend's app icon.
//
//   swift tools/make-icon.swift              → /tmp/HyperSend.iconset
//   iconutil -c icns /tmp/HyperSend.iconset -o mac/HyperSend.icns
//
// Why a script and not a checked-in PNG: the mark is four lines of geometry, so
// the icon can be re-rendered at any size, retinted, or regenerated on a machine
// that has never seen the original artwork. Every size is drawn from scratch
// rather than downscaled from one master — a 16 pt icon rendered as vectors
// keeps its stroke weight, where a 1024 pt reduction turns to mush.
//
// The mark is the product: two lanes, one carrying up and one carrying down,
// bonded side by side on graphite. No rocket, no cloud, no folder.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette
//
// Desaturated on purpose. Saturated arrows on a dark body vibrate at small
// sizes; these read as light strokes with a tint, not as neon.

let bodyTop = (r: 44.0, g: 47.0, b: 54.0)
let bodyBottom = (r: 17.0, g: 19.0, b: 23.0)
let laneUp = (r: 158.0, g: 194.0, b: 246.0)   // Wi-Fi, matching the UI
let laneDown = (r: 147.0, g: 216.0, b: 172.0) // USB cable, matching the UI

func srgb(_ c: (r: Double, g: Double, b: Double), _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: alpha)
}

// MARK: - Rendering

func render(size: Int) -> CGImage? {
    let side = CGFloat(size)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: size,
              height: size,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
          )
    else { return nil }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: the squircle occupies roughly 80% of the canvas, and
    // everything left over is the margin the Dock and Finder expect.
    let inset = side * 0.0985
    let square = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = square.width * 0.2237
    let body = CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // ── Body ────────────────────────────────────────────────────────────────
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()

    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [srgb(bodyTop), srgb(bodyBottom)] as CFArray,
        locations: [0, 1],
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: square.midX, y: square.maxY),
            end: CGPoint(x: square.midX, y: square.minY),
            options: [],
        )
    }

    // One soft light from above, so the surface is not perfectly even — the
    // same single-source lighting the window texture uses.
    if let sheen = CGGradient(
        colorsSpace: space,
        colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13),
                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1],
    ) {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: square.midX, y: square.maxY),
            end: CGPoint(x: square.midX, y: square.midY),
            options: [],
        )
    }

    // ── Mark ────────────────────────────────────────────────────────────────
    let stroke = square.width * 0.072
    let halfWidth = square.width * 0.098

    func lane(x: CGFloat, up: Bool, tint: CGColor) {
        let shaftTop = square.minY + square.height * 0.255
        let shaftBottom = square.minY + square.height * 0.745

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(tint)

        // Shaft.
        ctx.move(to: CGPoint(x: x, y: up ? shaftBottom : shaftTop))
        ctx.addLine(to: CGPoint(x: x, y: up ? shaftTop : shaftBottom))
        ctx.strokePath()

        // Head — a chevron, so the stroke weight matches the shaft exactly.
        let tipY = up ? shaftTop : shaftBottom
        let baseY = up ? tipY - square.height * 0.155 : tipY + square.height * 0.155
        ctx.move(to: CGPoint(x: x - halfWidth, y: baseY))
        ctx.addLine(to: CGPoint(x: x, y: tipY))
        ctx.addLine(to: CGPoint(x: x + halfWidth, y: baseY))
        ctx.strokePath()
    }

    lane(x: square.minX + square.width * 0.355, up: true, tint: srgb(laneUp))
    lane(x: square.minX + square.width * 0.645, up: false, tint: srgb(laneDown))

    ctx.restoreGState()

    // ── Edge ────────────────────────────────────────────────────────────────
    // A hairline rim: without it the body melts into a dark Dock.
    ctx.addPath(body)
    ctx.setLineWidth(max(1, side * 0.004))
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.strokePath()

    return ctx.makeImage()
}

// MARK: - Emit

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil,
    ) else {
        FileHandle.standardError.write(Data("cannot write \(path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("failed to finalise \(path)\n".utf8))
        exit(1)
    }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/HyperSend.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// name → pixel size. Both the 1× and 2× slot of every entry iconutil wants.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in variants {
    guard let image = render(size: size) else {
        FileHandle.standardError.write(Data("render failed at \(size)px\n".utf8))
        exit(1)
    }
    write(image, to: "\(outDir)/\(name).png")
}

print("wrote \(variants.count) PNGs to \(outDir)")
