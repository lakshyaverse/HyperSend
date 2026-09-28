import CoreGraphics
import ImageIO
import Foundation

// Dev tool: print a coarse color map of a PNG so an icon can be checked
// without eyeballing it. Usage: swiftc analysis.swift -o /tmp/imgmap && /tmp/imgmap <path>
guard CommandLine.arguments.count > 1 else { exit(1) }
let path = CommandLine.arguments[1]
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("load fail"); exit(1) }
let w = img.width, h = img.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
func hex(_ fx: Double, _ fy: Double) -> String {
    let x = min(w - 1, Int(Double(w) * fx)), y = min(h - 1, Int(Double(h) * (1.0 - fy)))
    let i = (y * w + x) * 4
    return String(format: "#%02x%02x%02x", buf[i], buf[i + 1], buf[i + 2])
}
print("grid (top → bottom):")
for fy in [0.08, 0.3, 0.5, 0.7, 0.92] {
    print(String(format: " y=%.2f  ", fy), [0.1, 0.3, 0.5, 0.7, 0.9].map { hex($0, fy) }.joined(separator: " "))
}
var r = 0, g = 0, b = 0, n = 0
var i = 0
while i < buf.count {
    if buf[i + 3] > 32 { r += Int(buf[i]); g += Int(buf[i + 1]); b += Int(buf[i + 2]); n += 1 }
    i += 4096
}
print(String(format: "mean: #%02x%02x%02x", r / n, g / n, b / n))
