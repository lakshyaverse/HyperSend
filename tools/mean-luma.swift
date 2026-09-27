#!/usr/bin/env swift
// Prints the mean luminance of a PNG (0-255). Used to quantify washout:
//   xcrun swift tools/mean-luma.swift a.png [b.png ...]

import CoreGraphics
import Foundation
import ImageIO

for path in CommandLine.arguments.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("\(path): unreadable")
        continue
    }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var total = 0.0
    let count = width * height
    for i in 0 ..< count {
        let o = i * 4
        total += 0.299 * Double(pixels[o]) + 0.587 * Double(pixels[o + 1]) + 0.114 * Double(pixels[o + 2])
    }
    print("\(path): mean luma \(String(format: "%.1f", total / Double(count)))")
}
