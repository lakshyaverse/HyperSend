#!/usr/bin/env swift
// Prints a luminance profile along one horizontal scanline, so an edge can be
// classified by shape: a 1-2 px spike is a stroke, a plateau jump is a fill
// boundary, a long ramp is a gradient.
//
//   xcrun swift tools/lum-line.swift /tmp/live2.png 0.52 0 0.18

import AppKit

let path = CommandLine.arguments[1]
let yF = Double(CommandLine.arguments[2])!
let x0F = Double(CommandLine.arguments[3])!
let x1F = Double(CommandLine.arguments[4])!

guard let image = NSImage(contentsOfFile: path),
      let rep = NSBitmapImageRep(data: image.tiffRepresentation!)
else { fatalError("cannot read \(path)") }

let w = rep.pixelsWide, h = rep.pixelsHigh
let y = Int(yF * Double(h))
let x0 = Int(x0F * Double(w)), x1 = Int(x1F * Double(w))

func lum(_ x: Int) -> Int {
    guard let c = rep.colorAt(x: x, y: y) else { return 0 }
    let v = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    return Int((v * 255).rounded())
}

var line = ""
var last = -1
for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 90)) {
    let v = lum(x)
    // Compress runs: print the value only when it changes by >=2.
    if last < 0 || abs(v - last) >= 2 {
        line += "\(v) "
        last = v
    }
}
print("y=\(String(format: "%.3f", yF)) · luminance left→right:")
print(line)
