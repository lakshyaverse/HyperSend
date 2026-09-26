import AppKit
import SwiftUI

// The window's texture.
//
// A flat window colour makes Liquid Glass look like grey plastic, and a rainbow
// gradient behind it looks like a screensaver. What actually reads as premium is
// *tooth*: a fine, even grain over a barely-there light, so the surface has
// something to catch and the glass has something to dissolve.
//
// The grain is generated once into a small tile and repeated, which is both
// pixel-exact and free to draw — no per-frame noise, no image asset to ship.

enum Grain {
    /// Deterministic, so the texture is identical on every launch. A texture
    /// that reshuffles itself each time the app opens looks broken.
    private static var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let lock = NSLock()
    private static let cache = NSCache<NSString, NSImage>()

    private static func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// A square tile of monochrome noise centred on mid-grey, so it can be
    /// blended over any appearance without shifting the hue.
    static func tile(edge: Int = 192, spread: Int = 30) -> NSImage? {
        let key = "\(edge)x\(spread)" as NSString
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache.object(forKey: key) { return hit }

        let count = edge * edge
        var pixels = [UInt8](repeating: 255, count: count * 4)
        let floor = 128 - spread / 2
        for index in 0..<count {
            let value = UInt8(clamping: floor + Int(next() >> 40) % (spread + 1))
            let offset = index * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: edge,
                  height: edge,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: edge * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent,
              )
        else { return nil }

        let nsImage = NSImage(cgImage: image, size: NSSize(width: edge, height: edge))
        cache.setObject(nsImage, forKey: key)
        return nsImage
    }
}

/// The grain, tiled to fill whatever it is given.
///
/// Drawn with `.overlay` blending rather than plain alpha. Alpha would wash the
/// surface toward mid-grey — the noise's mean sits at 128, so any real opacity
/// would lighten a dark window considerably. Overlay instead *modulates* the
/// surface: it darkens the dark half and lightens the light half, so the mean
/// stays put and the texture reads as tooth in the material rather than dust on
/// top of it.
struct GrainOverlay: View {
    var opacity: Double
    var spread: Int = 56

    var body: some View {
        GeometryReader { proxy in
            if let tile = Grain.tile(spread: spread) {
                Image(nsImage: tile)
                    .resizable(resizingMode: .tile)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blendMode(.overlay)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The grain scaled by the user's setting — nothing at Off, full at Max.
struct SurfaceGrain: View {
    @Environment(\.glassIntensity) private var intensity

    var body: some View {
        GrainOverlay(opacity: 0.68 * intensity.strength)
    }
}

/// The whole window's surface: a neutral base, one soft light from the top, a
/// vignette to seat the corners, and grain over all of it.
///
/// Deliberately monochrome. The colour in this app comes from the content and
/// the single accent; the surface stays quiet so the glass is what you notice.
struct WindowTexture: View {
    @Environment(\.glassIntensity) private var intensity

    var body: some View {
        let strength = intensity.strength

        ZStack {
            Color(nsColor: .windowBackgroundColor)

            // One soft light, high and off-centre, so the surface is not
            // perfectly even. This is what the glass edge will dissolve into.
            RadialGradient(
                colors: [Color.white.opacity(0.06 * strength), .clear],
                center: UnitPoint(x: 0.28, y: 0.0),
                startRadius: 0,
                endRadius: 900,
            )

            // Vignette: pulls the eye to the middle and stops the corners
            // reading as flat fill.
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.16 * strength)],
                center: .center,
                startRadius: 260,
                endRadius: 900,
            )

            SurfaceGrain()
        }
        .ignoresSafeArea()
    }
}

#if DEBUG
#Preview("Texture — the surface") {
    ZStack {
        WindowTexture()
        VStack(alignment: .leading, spacing: 10) {
            Text("HyperSend")
                .font(.system(size: 22, weight: .semibold))
            Text("Grain, one soft light, a vignette. Nothing loud.")
                .foregroundStyle(.secondary)
            Text("Glass dissolves this, it does not cover it.")
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCapsule()
        }
        .padding(32)
    }
    .frame(width: 620, height: 380)
}
#endif
