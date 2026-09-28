import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Draws the HyperSend icon in the app's own visual language:
//
//   - the pastel sky from Scene.skyStops (the window's backdrop),
//   - a rounded-square glass lens floating on it, lit like the app's panels
//     (bright specular top edge, fresnel rim, soft ground shadow),
//   - a Wi-Fi arc and a USB arrow inside the lens — the two lanes —
//     drawn in the deep-blue glass ink the UI uses,
//   - a warm bloom and a violet counter-bloom behind the lens so the glass
//     has light to bend, exactly like the window's Scene.warmStops.
//
// Colors are lifted from mac/Sources/UI/Tokens.swift so the icon, the window
// and the Android app share one palette. Run: swift tools/make-icon.swift

let size = 1024
let s = CGFloat(size)

let skyTop = CGColor(red: 0.62, green: 0.83, blue: 0.99, alpha: 1)
let skyBottom = CGColor(red: 0.39, green: 0.58, blue: 0.98, alpha: 1)
let warm = CGColor(red: 1.00, green: 0.88, blue: 0.60, alpha: 1)
let violet = CGColor(red: 0.86, green: 0.85, blue: 1.00, alpha: 1)
// Deep-blue glass ink for lane marks — saturated enough to read at 32 px.
let ink = CGColor(red: 0.08, green: 0.22, blue: 0.58, alpha: 0.95)
let inkSoft = CGColor(red: 0.08, green: 0.22, blue: 0.58, alpha: 0.55)

let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// ── sky ──────────────────────────────────────────────────────────────────────
let sky = CGGradient(colorsSpace: nil, colors: [skyTop, skyBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: 0), options: [])

// ── blooms behind the lens (the light the glass refracts) ───────────────────
func bloom(_ color: CGColor, _ rect: CGRect) {
    let g = CGGradient(
        colorsSpace: nil,
        colors: [color.copy(alpha: 0.85), color.copy(alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawRadialGradient(
        g,
        startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
        endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: max(rect.width, rect.height) / 2,
        options: []
    )
    ctx.restoreGState()
}
bloom(warm, CGRect(x: s * 0.08, y: s * 0.55, width: s * 0.50, height: s * 0.42))
bloom(violet, CGRect(x: s * 0.50, y: s * 0.10, width: s * 0.42, height: s * 0.38))

// ── the glass lens ───────────────────────────────────────────────────────────
let lens = CGRect(x: s * 0.22, y: s * 0.22, width: s * 0.56, height: s * 0.56)
let radius: CGFloat = s * 0.14
let path = CGPath(roundedRect: lens, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Ground shadow: the lens floats.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.022), blur: s * 0.05,
              color: CGColor(red: 0.05, green: 0.15, blue: 0.40, alpha: 0.35))
ctx.addPath(path)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
ctx.fillPath()
ctx.restoreGState()

// Glass body: vertical white sheen, brighter at the top like the panels.
let glass = CGGradient(
    colorsSpace: nil,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.62),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
        CGColor(red: 0.92, green: 0.96, blue: 1, alpha: 0.42),
    ] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.drawLinearGradient(glass, start: CGPoint(x: lens.midX, y: lens.maxY),
                       end: CGPoint(x: lens.midX, y: lens.minY), options: [])
ctx.restoreGState()

// Fresnel rim: bright specular on the lit edge, fading around.
ctx.saveGState()
ctx.addPath(path)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.setLineWidth(s * 0.012)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(
    colorsSpace: nil,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.25),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.75),
    ] as CFArray,
    locations: [0, 0.5, 1]
)!
ctx.drawLinearGradient(rim, start: CGPoint(x: lens.minX, y: lens.maxY),
                       end: CGPoint(x: lens.maxX, y: lens.minY), options: [])
ctx.restoreGState()

// ── the two lanes, inside the lens ──────────────────────────────────────────
let cx = lens.midX
let cy = lens.midY

// Wi-Fi arcs (three strokes), the radio lane.
func arc(_ radius: CGFloat, _ width: CGFloat, _ color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: cx, y: cy - s * 0.055), radius: radius,
               startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: true)
    ctx.strokePath()
}
arc(s * 0.075, s * 0.022, inkSoft)
arc(s * 0.135, s * 0.026, ink.copy(alpha: 0.8)!)
arc(s * 0.195, s * 0.030, ink)

// The dot under the arcs doubles as the USB arrow's tail origin.
ctx.setFillColor(ink)
ctx.fillEllipse(in: CGRect(x: cx - s * 0.024, y: cy - s * 0.10, width: s * 0.048, height: s * 0.048))

// USB lane: an arrow arcing under the Wi-Fi mark, cable to device.
let usbY = cy + s * 0.155
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: cx - s * 0.135, y: usbY))
arrow.addCurve(
    to: CGPoint(x: cx + s * 0.135, y: usbY),
    control1: CGPoint(x: cx - s * 0.045, y: usbY + s * 0.085),
    control2: CGPoint(x: cx + s * 0.045, y: usbY + s * 0.085)
)
ctx.addPath(arrow)
ctx.setStrokeColor(ink.copy(alpha: 0.9)!)
ctx.setLineWidth(s * 0.026)
ctx.setLineCap(.round)
ctx.strokePath()
// Arrowhead.
ctx.setFillColor(ink)
let head = CGMutablePath()
let tipX = cx + s * 0.145, tipY = usbY
head.move(to: CGPoint(x: tipX + s * 0.020, y: tipY))
head.addLine(to: CGPoint(x: tipX - s * 0.022, y: tipY + s * 0.040))
head.addLine(to: CGPoint(x: tipX - s * 0.022, y: tipY - s * 0.040))
head.closeSubpath()
ctx.addPath(head)
ctx.fillPath()

// ── write the master PNG ─────────────────────────────────────────────────────
let image = ctx.makeImage()!
let out = URL(fileURLWithPath: "assets/icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("failed to write \(out.path)\n".utf8)); exit(1)
}
print("wrote \(out.path) (\(size)x\(size))")
