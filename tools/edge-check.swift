#!/usr/bin/env swift
// Scans a screenshot for hard rectangular edges in the backdrop: walks
// horizontal scanlines and reports the biggest adjacent-pixel colour step.
// A smooth gradient steps <2 RGB per pixel; a clipped bloom edge steps 6+.
//
//   xcrun swift tools/edge-check.swift /tmp/app-glass2.png [yStart yEnd xStart xEnd]
//
// Ratios, not pixels, so the same command works on any window size.

import AppKit

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard let image = NSImage(contentsOfFile: path),
      let rep = NSBitmapImageRep(data: image.tiffRepresentation!)
else { fatalError("cannot read \(path)") }

let w = rep.pixelsWide, h = rep.pixelsHigh

func ratio(_ s: String, _ fallback: Double) -> Double {
    CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2 + Int(fallback * 4)]) ?? fallback : fallback
}
// Optional band: yStart yEnd xStart xEnd as fractions of the image.
var ys = 0.15, ye = 0.50, xs = 0.05, xe = 0.95
if CommandLine.arguments.count >= 6 {
    ys = Double(CommandLine.arguments[2]) ?? ys
    ye = Double(CommandLine.arguments[3]) ?? ye
    xs = Double(CommandLine.arguments[4]) ?? xs
    xe = Double(CommandLine.arguments[5]) ?? xe
}

let y0 = Int(ys * Double(h)), y1 = Int(ye * Double(h))
let x0 = Int(xs * Double(w)), x1 = Int(xe * Double(w))

func lum(_ x: Int, _ y: Int) -> Double {
    guard let c = rep.colorAt(x: x, y: y) else { return 0 }
    return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
}

var worst = 0.0, worstX = 0, worstY = 0
var y = y0
while y < y1 {
    var x = x0 + 1
    while x < x1 {
        let d = abs(lum(x, y) - lum(x - 1, y))
        if d > worst { worst = d; worstX = x; worstY = y }
        x += 1
    }
    y += 2
}

print(String(format: "scanned %dx%d band · max adjacent-pixel step: %.3f (%.1f RGB) at (%.2f, %.2f)",
             x1 - x0, y1 - y0, worst, worst * 255,
             Double(worstX) / Double(w), Double(worstY) / Double(h)))
print(worst * 255 < 2.5 ? "SMOOTH — no boxy edges in this band" : "HARD EDGE DETECTED — something is still clipping")
