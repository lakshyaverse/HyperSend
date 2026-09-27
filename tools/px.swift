import Foundation
import CoreGraphics
import ImageIO

// px.swift — print the colour at one or more points of a PNG.
//
//   swift tools/px.swift shot.png 60,700 540,145 540,1140
//
// Built for the UI pass: eyeballing a screenshot tells you "that looks washed",
// sampling it tells you the panel is #F6F8FE sitting on a #BDD0FA sky, which is
// a two-line fix. Prints hex plus the alpha, so glass can be checked too.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: px.swift <png> x,y [x,y ...]\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: args[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

let w = image.width
let h = image.height
var bytes = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(
    data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

print("\(args[1])  \(w)x\(h)")

// "--scan x0 y0 x1 y1" reports the brightest and darkest pixel in a region
// plus the mean — enough to tell "this text is dimmed" from "this text is fine".
if args.count >= 7, args[2] == "--scan" {
    let box = args[3...6].compactMap { Int($0) }
    var best = (sum: -1, hex: "", x: 0, y: 0)
    var worst = (sum: Int.max, hex: "", x: 0, y: 0)
    var total = 0.0
    var n = 0
    for y in max(0, box[1])..<min(h, box[3]) {
        for x in max(0, box[0])..<min(w, box[2]) {
            let i = (y * w + x) * 4
            let (r, g, b) = (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
            let sum = r + g + b
            if sum > best.sum { best = (sum, String(format: "#%02X%02X%02X", r, g, b), x, y) }
            if sum < worst.sum { worst = (sum, String(format: "#%02X%02X%02X", r, g, b), x, y) }
            total += Double(sum) / 3.0
            n += 1
        }
    }
    print("  brightest \(best.hex) at \(best.x),\(best.y)")
    print("  darkest   \(worst.hex) at \(worst.x),\(worst.y)")
    print(String(format: "  mean      %.1f  (%d px)", total / Double(max(1, n)), n))
    exit(0)
}

for spec in args.dropFirst(2) {
    let parts = spec.split(separator: ",").compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 0, parts[1] >= 0, parts[0] < w, parts[1] < h else {
        print("  \(spec) -> out of bounds")
        continue
    }
    let i = (parts[1] * w + parts[0]) * 4
    let hex = String(format: "#%02X%02X%02X", bytes[i], bytes[i + 1], bytes[i + 2])
    print(String(format: "  %4d,%4d -> %@", parts[0], parts[1], hex))
}
