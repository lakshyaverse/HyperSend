import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// crop.swift — cut a region out of a screenshot so it can be looked at closely.
//
//   swift tools/crop.swift shot.png out.png 1120 1400        (full width band)
//   swift tools/crop.swift shot.png out.png 0 1120 1080 280  (x y w h)
//
// Pixel sampling tells you a colour is wrong; cropping tells you why.

let a = CommandLine.arguments
guard a.count >= 5 else {
    FileHandle.standardError.write(Data("usage: crop.swift <in> <out> <y0> <y1> [x0 x1]\n".utf8))
    exit(2)
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }

let w = img.width, h = img.height
let y0 = max(0, Int(a[3])!), y1 = min(h, Int(a[4])!)
let x0 = a.count >= 7 ? max(0, Int(a[5])!) : 0
let x1 = a.count >= 7 ? min(w, Int(a[6])!) : w
guard y1 > y0, x1 > x0, let cut = img.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else {
    FileHandle.standardError.write(Data("bad crop\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: a[2])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, cut, nil)
CGImageDestinationFinalize(dest)
print("wrote \(a[2])  \(cut.width)x\(cut.height)")
