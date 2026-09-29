import Foundation
import CoreGraphics
import ImageIO

// edge.swift — trace where a vertical edge sits on each scanline of a PNG.
//
//   swift tools/edge.swift shot.png Y0 Y1 XMIN XMAX
//
// For every row in [Y0, Y1) it finds the x in [XMIN, XMAX] with the strongest
// horizontal luma gradient and prints `y x`. Feed the output to a corner fit:
// a straight edge shows a constant x, and as the trace approaches a rounded
// corner the x walks outward, which is exactly the corner's curvature.
//
// Exists because "the corners look blocky" is a claim about geometry, not
// taste — this turns it into numbers you can compare across two screenshots.

let a = CommandLine.arguments
guard a.count >= 6 else {
    FileHandle.standardError.write(Data("usage: edge.swift <png> y0 y1 xmin xmax\n".utf8))
    exit(2)
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(a[1])\n".utf8))
    exit(1)
}
let y0 = Int(a[2])!, y1 = Int(a[3])!, xmin = Int(a[4])!, xmax = Int(a[5])!

let w = img.width, h = img.height
var bytes = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(
    data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

func luma(_ x: Int, _ y: Int) -> Double {
    let i = (y * w + x) * 4
    return 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
}

let lo = max(1, xmin), hi = min(w - 2, xmax)
for y in max(0, y0)..<min(h, y1) {
    var bestX = -1
    var best = 0.0
    for x in lo...hi {
        let g = abs(luma(x + 1, y) - luma(x - 1, y))
        if g > best { best = g; bestX = x }
    }
    if bestX >= 0 { print("\(y) \(bestX) \(String(format: "%.1f", best))") }
}
