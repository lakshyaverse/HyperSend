#!/usr/bin/env swift
// Measures the drop refraction from a burst of window screenshots.
//
//   xcrun swift tools/ripple-frames.swift <dir> <count> <cx> <cy>
//
// Expects PNGs named 01.png…NN.png captured back-to-back during a simulated
// drop, plus the impact point (cx, cy) in captured-image pixels. For each
// frame it reports:
//   * luminance profile along the horizontal line through the impact —
//     spikes = the crest/trough light rings,
//   * horizontal pixel displacement at probe rows above and below that line,
//     found by cross-correlating each row against the last frame's same row —
//     nonzero displacement = the glass content actually moved (refraction).
//
// Exit summary prints the max ring spike and max displacement observed.

import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count >= 5 else {
    print("usage: ripple-frames.swift <dir> <count> <cx> <cy>")
    exit(2)
}
let dir = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 0
let cx = Int(Double(CommandLine.arguments[3]) ?? 0)
let cy = Int(Double(CommandLine.arguments[4]) ?? 0)

func loadLuma(_ path: String) -> [Float]? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Downsample to luminance at unit stride.
    var luma = [Float](repeating: 0, count: width * height)
    for i in 0 ..< width * height {
        let o = i * 4
        luma[i] = 0.299 * Float(pixels[o]) + 0.587 * Float(pixels[o + 1]) + 0.114 * Float(pixels[o + 2])
    }
    return luma
}

struct Frame {
    var name: String
    var luma: [Float]
    var width: Int
    var height: Int
}

var frames: [Frame] = []
for i in 1 ... max(count, 1) {
    let name = String(format: "%02d.png", i)
    let path = dir + "/" + name
    guard let luma = loadLuma(path) else {
        fputs("missing or unreadable \(path)\n", stderr)
        exit(2)
    }
    // All captures share the window size; take dimensions from the first.
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(2) }
    frames.append(Frame(name: name, luma: luma, width: img.width, height: img.height))
}

guard let first = frames.first else { exit(2) }
let width = first.width, height = first.height
guard cx > 0, cx < width, cy > 0, cy < height else {
    fputs("impact point (\(cx),\(cy)) outside frame \(width)x\(height)\n", stderr)
    exit(2)
}

var maxSpike: Float = 0
var maxDisplacement = 0

for (index, frame) in frames.enumerated() {
    // Luminance along the row through the impact point: find the largest
    // deviation from the previous frame on that row (light rings moving).
    var spike: Float = 0
    if index > 0 {
        let previous = frames[index - 1]
        for x in stride(from: max(0, cx - 300), to: min(width, cx + 300), by: 2) {
            let d = abs(frame.luma[cy * width + x] - previous.luma[cy * width + x])
            spike = max(spike, d)
        }
    }
    maxSpike = max(maxSpike, spike)

    // Horizontal displacement on probe rows above and below the impact:
    // cross-correlate a window against the previous frame's same row.
    var displacement = 0
    if index > 0 {
        let previous = frames[index - 1]
        for rowDelta in [-60, -30, 30, 60] {
            let y = cy + rowDelta
            guard y > 10, y < height - 10 else { continue }
            let window = 40
            let maxShift = 22
            var bestScore = Float.greatestFiniteMagnitude
            var bestShift = 0
            for shift in -maxShift ... maxShift {
                var score: Float = 0
                for x in (cx - window) ..< (cx + window) {
                    let sx = min(max(x + shift, 0), width - 1)
                    score += abs(frame.luma[y * width + x] - previous.luma[y * width + sx])
                }
                if score < bestScore {
                    bestScore = score
                    bestShift = shift
                }
            }
            displacement = max(displacement, abs(bestShift))
        }
    }
    maxDisplacement = max(maxDisplacement, displacement)

    let ring = spike > 6 ? "ring!" : ""
    let moved = displacement >= 3 ? "MOVED" : ""
    print("\(frame.name): rowSpike=\(Int(spike)) \(ring)  hDisp=\(displacement)px \(moved)")
}

print("----")
print("max ring spike: \(Int(maxSpike))  max horizontal displacement: \(maxDisplacement)px")
print(maxDisplacement >= 3 ? "REFRACTION DETECTED" : "NO REFRACTION (displacement below noise floor)")
