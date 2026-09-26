#!/usr/bin/env swift
//
// pixelcheck — read numbers off a screenshot.
//
// The agent driving this repo cannot see the rendered window, so a capture is
// only useful if it can be measured. This prints the three things that matter
// when judging a glass + texture interface:
//
//   map      a coarse block-luminance grid, so the layout is visible as numbers
//   region   mean / standard deviation / high-frequency energy of one rectangle
//   profile  a row of raw luminances, for measuring how an edge fades
//
// "High-frequency energy" is the mean absolute difference between horizontally
// adjacent pixels. A flat fill scores ~0; fine grain scores a small non-zero
// value; blurring or dissolving it must lower it. That is how the texture and
// the dissolve get verified without eyes.
//
// Usage:
//   swift tools/pixelcheck.swift shot.png map [cols rows]
//   swift tools/pixelcheck.swift shot.png region X Y W H
//   swift tools/pixelcheck.swift shot.png profile Y X0 X1 [step]
//   swift tools/pixelcheck.swift shot.png edge Y X0 X1
//
// Coordinates are in pixels of the image, origin top-left.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: pixelcheck <png> <map|region|profile|edge> ...\n".data(using: .utf8)!)
    exit(2)
}

let path = args[1]
let mode = args[2]

guard let image = NSImage(contentsOfFile: path),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(1)
}

let width = cg.width
let height = cg.height
var buffer = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(
    data: &buffer,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
) else { exit(1) }

// Flip so row 0 is the top of the image, matching how the shot is described.
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)
context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

@inline(__always)
func luminance(_ x: Int, _ y: Int) -> Double {
    let offset = (y * width + x) * 4
    return 0.2126 * Double(buffer[offset])
        + 0.7152 * Double(buffer[offset + 1])
        + 0.0722 * Double(buffer[offset + 2])
}

func int(_ index: Int, _ fallback: Int) -> Int {
    guard index < args.count, let value = Int(args[index]) else { return fallback }
    return value
}

/// Mean absolute horizontal-gradient magnitude over a rectangle.
func highFrequency(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Double {
    guard w > 1, h > 0 else { return 0 }
    var total = 0.0
    var samples = 0
    for row in y..<(y + h) {
        guard row >= 0, row < height else { continue }
        for column in x..<(x + w - 1) {
            guard column >= 0, column < width - 1 else { continue }
            total += abs(luminance(column + 1, row) - luminance(column, row))
            samples += 1
        }
    }
    return samples == 0 ? 0 : total / Double(samples)
}

func describe(_ label: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
    var sum = 0.0
    var sumSquares = 0.0
    var count = 0
    for row in y..<(y + h) where row >= 0 && row < height {
        for column in x..<(x + w) where column >= 0 && column < width {
            let value = luminance(column, row)
            sum += value
            sumSquares += value * value
            count += 1
        }
    }
    guard count > 0 else { print("\(label): empty region"); return }
    let mean = sum / Double(count)
    let variance = max(0, sumSquares / Double(count) - mean * mean)
    print(String(
        format: "%@ x=%d y=%d w=%d h=%d  mean=%.2f  sd=%.2f  highfreq=%.3f",
        label, x, y, w, h, mean, variance.squareRoot(), highFrequency(x, y, w, h),
    ))
}

switch mode {
case "map":
    let columns = int(3, 48)
    let rows = int(4, 24)
    print("map \(width)x\(height)  cell=\(width / columns)x\(height / rows)")
    print("      " + (0..<columns).map { String(format: "%4d", $0) }.joined())
    for row in 0..<rows {
        let y0 = row * height / rows
        let y1 = (row + 1) * height / rows
        var line = String(format: "%4d |", row)
        for column in 0..<columns {
            let x0 = column * width / columns
            let x1 = (column + 1) * width / columns
            var total = 0.0
            var count = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    total += luminance(x, y)
                    count += 1
                }
            }
            line += String(format: "%4d", count == 0 ? 0 : Int(total / Double(count)))
        }
        print(line)
    }

case "region":
    describe("region", int(3, 0), int(4, 0), int(5, 100), int(6, 100))

case "profile":
    let y = int(3, 0)
    let x0 = int(4, 0)
    let x1 = int(5, width - 1)
    let step = max(1, int(6, 1))
    guard y >= 0, y < height else { print("row out of range"); exit(1) }
    print("profile y=\(y) x=\(x0)…\(x1) step=\(step)")
    var line = ""
    for x in stride(from: x0, through: min(x1, width - 1), by: step) {
        line += String(format: "%6.1f", luminance(x, y))
    }
    print(line)

case "edge":
    // Where does a transition start and finish? Prints the run length over
    // which luminance moves from 10% to 90% of its total change — a hard edge
    // is 1–3 px, a dissolved one is tens of px.
    let y = int(3, 0)
    let x0 = int(4, 0)
    let x1 = int(5, width - 1)
    let limit = min(x1, width - 1)
    guard y >= 0, y < height, limit > x0 + 2 else { print("bad range"); exit(1) }
    let values = (x0...limit).map { luminance($0, y) }
    let start = values.first ?? 0
    let end = values.last ?? 0
    let delta = end - start
    guard abs(delta) > 1 else { print("edge y=\(y): no transition (Δ=\(String(format: "%.2f", delta)))"); exit(0) }
    let total = Double(limit - x0)
    var low10 = -1
    var high90 = -1
    for (index, value) in values.enumerated() {
        let progress = (value - start) / delta
        if low10 < 0, progress >= 0.10 { low10 = index }
        if high90 < 0, progress >= 0.90 { high90 = index }
    }
    let pixels = Double(high90 - low10)
    print(String(
        format: "edge y=%d: %.2f → %.2f (Δ=%.2f) over %d px; 10–90%% fade = %.0f px of %.0f (%.0f%% of the span)",
        y, start, end, delta, limit - x0, pixels, total, 100 * pixels / max(total, 1),
    ))

default:
    FileHandle.standardError.write("unknown mode \(mode)\n".data(using: .utf8)!)
    exit(2)
}
