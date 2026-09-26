import AppKit
import SwiftUI

// The MagneticDock — a Dock-like glass bar of buttons that are *physical*.
//
// Why an NSView and not SwiftUI: the magnet needs the cursor's position over the
// bar on every mouse-move, and a display-link spring loop that rewrites button
// geometry at up to 120 fps. Both are AppKit's home turf.
//
// The glass is the system's own: each button is a bare NSGlassEffectView — the
// exact AppKit class behind Liquid Glass on macOS 26+ — with its icon as
// contentView, inside an NSGlassEffectContainerView so neighbouring buttons
// merge into one shape as they swell together. On macOS 27 the glass is
// `effectIsInteractive`, per the header: "enabled for glass that is used as the
// background for interactive controls". Below 26, the same code path hosts the
// icon in an NSVisualEffectView instead. One binary, the native material
// everywhere — and crucially, glass on the window, never glass on glass: the
// container draws nothing of its own.
//
// Physics, per button, every frame:
//
//   x″ = k·(xHome − x) − c·x′ + attraction(cursor)
//
// Inside the magnet radius a button is pulled toward the cursor with
// inverse-falloff strength; the pull must dominate the home spring at the
// cursor or the button never leaves home — the previous build's equilibrium was
// about one pixel, which read as "nothing happens". Scale and lift are driven
// by the same displacement as the pull, so a button is never somewhere its size
// disagrees with.

final class MagneticDockView: NSView {
    struct Item {
        var symbol: String
        var help: String
        var action: () -> Void
    }

    // MARK: tuning

    /// Under-damped on purpose (ζ ≈ 0.6): the return home should overshoot
    /// once, like the Dock.
    private let stiffness: CGFloat = 170
    private let damping: CGFloat = 11

    /// Attraction strength, in points-per-second² at full proximity. Sits well
    /// above `stiffness × oneButtonSpacing` so the cursor wins the tug-of-war —
    /// this was the previous build's failure: a 15-point pull against a
    /// 170×12 ≈ 2000-point spring force goes nowhere.
    private let magnetForce: CGFloat = 5200

    /// How far the magnet reaches, in points beyond the touched button.
    private let magnetRadius: CGFloat = 130

    private let buttonSize: CGFloat = 48
    private let baseGap: CGFloat = 14
    /// A fully-attracted button swells to 1.45× and lifts 10 pt — the Dock's
    /// proportions, which is the interaction being copied.
    private let maxMagnify: CGFloat = 0.45
    private let maxLift: CGFloat = 10

    // MARK: state

    private var items: [Item] = []
    private var glass: [NSView] = []
    private var homeX: [CGFloat] = []
    private var posX: [CGFloat] = []
    private var velX: [CGFloat] = []
    private var scale: [CGFloat] = []
    private var scaleVel: [CGFloat] = []

    private var tracking: NSTrackingArea?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var cursorInside = false

    // MARK: setup

    func setItems(_ newItems: [Item]) {
        guard newItems.map(\.symbol) != items.map(\.symbol) else { return }
        items = newItems

        glass.forEach { $0.removeFromSuperview() }
        glass = []
        homeX = []
        posX = []
        velX = []
        scale = []
        scaleVel = []

        let container: NSView
        if #available(macOS 26.0, *) {
            // Merges descendant glass views that come within `spacing` of each
            // other — so swelling buttons fuse at the rims instead of colliding.
            let merge = NSGlassEffectContainerView()
            merge.spacing = baseGap + 6
            container = merge
        } else {
            container = NSView()
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        for (index, item) in items.enumerated() {
            let effect = makeGlassButton(symbol: item.symbol, help: item.help, tag: index)
            effect.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(effect)

            glass.append(effect)
            homeX.append(0)
            posX.append(0)
            velX.append(0)
            scale.append(0)
            scaleVel.append(0)
        }
        needsLayout = true
    }

    /// A bare glass circle with the icon as its contentView — the exact usage
    /// the header describes. No material behind it, no glow layered on it.
    private func makeGlassButton(symbol: String, help: String, tag: Int) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: help,
        )?
        .withSymbolConfiguration(.init(pointSize: UI.Icon.control, weight: .medium))
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.cornerRadius = buttonSize / 2
            effect.contentView = icon
            if #available(macOS 27.0, *) {
                effect.effectIsInteractive = true
            }
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: UI.Icon.dock),
                icon.heightAnchor.constraint(equalToConstant: UI.Icon.dock),
            ])
            return effect
        }

        // Pre-26: same geometry, system material instead of glass.
        let fallback = NSVisualEffectView()
        fallback.wantsLayer = true
        fallback.material = .hudWindow
        fallback.state = .active
        fallback.blendingMode = .withinWindow
        fallback.layer?.cornerRadius = buttonSize / 2
        fallback.layer?.masksToBounds = true
        fallback.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        fallback.layer?.borderWidth = 0.5
        fallback.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: fallback.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: fallback.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
        return fallback
    }

    // MARK: layout

    override func layout() {
        super.layout()
        guard glass.count == items.count, !glass.isEmpty, bounds.width > 0 else { return }

        let count = CGFloat(glass.count)
        let barWidth = count * buttonSize + (count - 1) * baseGap
        let baseY = (bounds.height - buttonSize) / 2
        var x = (bounds.width - barWidth) / 2

        for index in 0..<glass.count {
            homeX[index] = x + buttonSize / 2
            if posX[index] == 0 { posX[index] = homeX[index] }
            x += buttonSize + baseGap
        }

        // Grow from the bar's centre line, so swell + lift reads as "toward
        // you" rather than "drifting up".
        for index in 0..<glass.count {
            let size = buttonSize * (1 + scale[index] * maxMagnify)
            let lift = scale[index] * maxLift
            glass[index].frame = CGRect(
                x: posX[index] - size / 2,
                y: baseY + (buttonSize - size) / 2 - lift,
                width: size,
                height: size,
            ).integral
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: buttonSize + 26)
    }

    // MARK: input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds.insetBy(dx: -30, dy: -30),
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        cursorInside = true
        startLink()
    }

    override func mouseMoved(with event: NSEvent) {
        cursorInside = true
        startLink()
    }

    override func mouseExited(with event: NSEvent) {
        cursorInside = false
        startLink()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = touchedButton(at: convert(event.locationInWindow, from: nil)) else { return }
        // Squash on press; the spring carries the recovery, so the button
        // visibly recoils and rings back instead of flickering.
        scale[index] -= 0.18
        scaleVel[index] += 3.4
        startLink()
        items[index].action()
    }

    private func touchedButton(at point: NSPoint) -> Int? {
        let reach = buttonSize / 2 + 6
        var best: (index: Int, distance: CGFloat)?
        for index in 0..<glass.count {
            let distance = abs(point.x - posX[index])
            if distance <= reach, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    // MARK: simulation

    private func startLink() {
        guard displayLink == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        // macOS's display link — CADisplayLink(target:) is iOS-only. It retains
        // its target, so it targets a Proxy that weakly references this view;
        // otherwise the loop would keep ticking on a torn-down view.
        displayLink = displayLink(target: Proxy(target: self), selector: #selector(Proxy.tick(_:)))
    }

    private func stopLinkIfNeeded() {
        guard !cursorInside else { return }
        let settled = zip(posX, homeX).allSatisfy { abs($0 - $1) < 0.1 }
            && velX.allSatisfy { abs($0) < 0.6 }
            && scaleVel.allSatisfy { abs($0) < 0.05 }
        if settled {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func step(_ dt: CGFloat) {
        var cursorX: CGFloat?
        if cursorInside, let window {
            cursorX = convert(window.mouseLocationOutsideOfEventStream, from: nil).x
        }

        for index in 0..<glass.count {
            var force = stiffness * (homeX[index] - posX[index]) - damping * velX[index]

            if let cursorX {
                let distance = posX[index] - cursorX
                let reach = magnetRadius + scale[index] * 40
                if abs(distance) < reach {
                    // Inverse-falloff: weak at the edge of reach, dominant at
                    // the cursor — the Dock's magnification curve.
                    let proximity = 1 - abs(distance) / reach
                    let direction: CGFloat = distance < 0 ? 1 : -1
                    force += direction * magnetForce * proximity * proximity
                }
            }

            velX[index] += force * dt
            posX[index] += velX[index] * dt

            // Swell rides proximity to the cursor, and follows through the
            // spring so it lags just enough to feel weighted.
            let displacement: CGFloat
            if let cursorX {
                let distance = abs(posX[index] - cursorX)
                displacement = max(0, 1 - distance / magnetRadius)
            } else {
                displacement = 0
            }
            let scaleForce = 170 * (displacement - scale[index]) - 12 * scaleVel[index]
            scaleVel[index] += scaleForce * dt
            scale[index] += scaleVel[index] * dt
        }
        needsLayout = true
    }

    /// Breaks the display link's retain cycle: it holds this box, the box holds
    /// the view weakly, and an orphaned link invalidates itself on the first
    /// tick after its view is gone.
    private final class Proxy {
        weak var target: MagneticDockView?
        init(target: MagneticDockView) { self.target = target }

        @objc func tick(_ link: CADisplayLink) {
            guard let target else { link.invalidate(); return }
            let dt = CGFloat(min(0.032, max(0.001, link.targetTimestamp - target.lastFrameTime)))
            target.lastFrameTime = link.targetTimestamp
            target.step(dt)
            target.stopLinkIfNeeded()
        }
    }

    deinit {
        displayLink?.invalidate()
    }
}

// MARK: - SwiftUI wrapper

/// The dock, in the window's bottom safe area where it can never cover content.
struct MagneticDock: NSViewRepresentable {
    var items: [MagneticDockView.Item]

    func makeNSView(context: Context) -> MagneticDockView {
        let view = MagneticDockView()
        view.setItems(items)
        return view
    }

    func updateNSView(_ view: MagneticDockView, context: Context) {
        view.setItems(items)
    }
}
