import Foundation
import CoreGraphics
import ImageIO

// ascii.swift — look at a screenshot from a terminal.
//
//   swift tools/ascii.swift shot.png [cols] [--inv] [--raw]
//
// Box-downsamples the image to `cols` columns, contrast-stretches the luma and
// maps it onto a character ramp, with the cell height doubled so the result is
// roughly square. Useless for judging colour (use px.swift) and excellent for
// judging layout: where the cards are, how big they are, whether anything
// overlaps or runs off the edge.
//
// `--inv` flips light-on-dark to dark-on-light, which reads better for a light
// UI on a dark terminal. `--raw` skips the contrast stretch.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ascii.swift <png> [cols] [--inv] [--raw]\n".utf8))
    exit(2)
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}
let cols = args.count >= 3 ? (Int(args[2]) ?? 88) : 88
let inverted = args.contains("--inv")
let raw = args.contains("--raw")

let w = img.width, h = img.height
var bytes = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(
    data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

let cellW = Double(w) / Double(cols)
let cellH = cellW * 2.0
let rows = max(1, Int(Double(h) / cellH))

// One mean luma per character cell.
var cells = [Double](repeating: 0, count: cols * rows)
for r in 0..<rows {
    for c in 0..<cols {
        let x0 = Int(Double(c) * cellW), x1 = min(w, Int(Double(c + 1) * cellW))
        let y0 = Int(Double(r) * cellH), y1 = min(h, Int(Double(r + 1) * cellH))
        var total = 0.0
        var n = 0
        for y in y0..<max(y0 + 1, y1) {
            for x in x0..<max(x0 + 1, x1) {
                let i = (y * w + x) * 4
                total += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
                n += 1
            }
        }
        cells[r * cols + c] = total / Double(max(1, n))
    }
}

var lo = cells.min() ?? 0, hi = cells.max() ?? 255
if raw || hi - lo < 1 { lo = 0; hi = 255 }

let ramp = Array(" .:-=+*#%@")
func glyph(_ v: Double) -> Character {
    let t = ((v - lo) / max(1.0, hi - lo)).clamped01()
    let idx = Int((inverted ? 1.0 - t : t) * Double(ramp.count - 1) + 0.5)
    return ramp[min(ramp.count - 1, max(0, idx))]
}

print("\(args[1])  \(w)x\(h)  ->  \(cols)x\(rows)  luma \(Int(lo))…\(Int(hi))")
for r in 0..<rows {
    var line = ""
    line.reserveCapacity(cols)
    for c in 0..<cols { line.append(glyph(cells[r * cols + c])) }
    print(line)
}

extension Double {
    func clamped01() -> Double { Swift.min(1.0, Swift.max(0.0, self)) }
}
