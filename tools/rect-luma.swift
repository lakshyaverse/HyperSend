#!/usr/bin/env swift
// Mean luminance of a rect region across PNGs, to localize brightness changes:
//   xcrun swift tools/rect-luma.swift x y w h a.png [b.png ...]
// Coordinates are in image pixels; pass -1 -1 -1 -1 for the whole image.

import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments.dropFirst().map { $0 }
guard args.count >= 5 else {
    print("usage: rect-luma.swift x y w h a.png [b.png ...]")
    exit(2)
}
let rx = Int(args[0]) ?? -1, ry = Int(args[1]) ?? -1
let rw = Int(args[2]) ?? -1, rh = Int(args[3]) ?? -1

for path in args.dropFirst(4) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("\(path): unreadable")
        continue
    }
    let width = image.width, height = image.height
    let x = rx < 0 ? 0 : rx, y = ry < 0 ? 0 : ry
    let w = rw < 0 ? width - x : min(rw, width - x)
    let h = rh < 0 ? height - y : min(rh, height - y)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var total = 0.0
    let count = w * h
    for j in y ..< (y + h) {
        for i in x ..< (x + w) {
            let o = (j * width + i) * 4
            total += 0.299 * Double(pixels[o]) + 0.587 * Double(pixels[o + 1]) + 0.114 * Double(pixels[o + 2])
        }
    }
    print("\(path) [\(x),\(y) \(w)x\(h)]: \(String(format: "%.1f", total / Double(max(count, 1))))")
}
