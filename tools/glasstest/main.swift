import AppKit
import QuartzCore

// Persistent Liquid Glass demo (AppKit-only — no SwiftUI macros, no Xcode
// needed). Shows a HyperSend-style glass card plus two "lane" pills that
// animate when you press Send, previewing the Wi-Fi + USB multipath UI.

final class BackdropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let g = CAGradientLayer()
        g.colors = [
            NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.45, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.65, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.55, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.45, alpha: 1).cgColor,
        ]
        g.locations = [0, 0.35, 0.7, 1]
        g.startPoint = CGPoint(x: 0, y: 0)
        g.endPoint = CGPoint(x: 1, y: 1)
        layer = g
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); layer?.frame = bounds }
}

/// A small glass pill: label + progress bar. Used for the per-lane readout.
final class LaneView: NSView {
    private let glass = NSGlassEffectView()
    private let name: NSTextField
    private let rate = NSTextField(labelWithString: "0.0 MB/s")
    private var progress: Double = 0
    private let bar = NSView()
    private let barFill = NSView()
    private let width: CGFloat

    init(title: String, tint: NSColor, width: CGFloat = 260) {
        self.name = NSTextField(labelWithString: title)
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        wantsLayer = true

        glass.style = .regular
        glass.cornerRadius = 16
        glass.tintColor = tint.withAlphaComponent(0.18)
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        addSubview(glass)

        name.font = .systemFont(ofSize: 12, weight: .semibold)
        rate.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rate.textColor = .secondaryLabelColor

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        bar.layer?.cornerRadius = 3
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = tint.cgColor
        barFill.layer?.cornerRadius = 3
        bar.addSubview(barFill)

        let row = NSStackView(views: [name, NSView(), rate])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(row)
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 6),
            bar.heightAnchor.constraint(equalToConstant: 6),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = host
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        barFill.frame = NSRect(x: 0, y: 0, width: bar.bounds.width * progress, height: 6)
    }

    func set(progress p: Double, rateText: String) {
        progress = max(0, min(1, p))
        rate.stringValue = rateText
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            barFill.animator().frame = NSRect(
                x: 0, y: 0, width: bar.bounds.width * progress, height: 6,
            )
        }
    }
}

final class GlassCardView: NSView {
    private let glass = NSGlassEffectView()
    private let title = NSTextField(labelWithString: "HyperSend")
    private let subtitle = NSTextField(labelWithString: "Drop files to send over Wi-Fi + USB")
    private let icon = NSImageView()
    private let button = NSButton()
    private let wifi = LaneView(title: "Wi-Fi  ·  hotspot lane", tint: .systemTeal)
    private let usb = LaneView(title: "USB  ·  cable lane", tint: .systemGreen)
    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        glass.style = .regular
        glass.cornerRadius = 30
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        addSubview(glass)

        icon.image = NSImage(
            systemSymbolName: "bolt.horizontal.circle.fill",
            accessibilityDescription: "HyperSend",
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        title.font = .systemFont(ofSize: 24, weight: .bold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        button.title = "Send 300 MB test file"
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(send)

        let stack = NSStackView(views: [icon, title, subtitle, wifi, usb, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 26, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            wifi.widthAnchor.constraint(equalToConstant: 300),
            usb.widthAnchor.constraint(equalToConstant: 300),
        ])
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = host
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); glass.frame = bounds }

    @objc private func send() {
        guard !busy else { return }
        busy = true
        button.title = "Sending…"
        subtitle.stringValue = "Two lanes active — radio + cable"
        var tick = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { return }
            tick += 1
            let p = min(1.0, Double(tick) / 24.0)
            // Wi-Fi lane ~28 MB/s, USB lane ~35 MB/s: the real measured numbers.
            self.wifi.set(progress: p, rateText: String(format: "%.1f MB/s", 28 * (0.7 + 0.3 * Double.random(in: 0...1))))
            self.usb.set(progress: p, rateText: String(format: "%.1f MB/s", 35 * (0.7 + 0.3 * Double.random(in: 0...1))))
            if p >= 1 {
                t.invalidate()
                self.busy = false
                self.button.title = "Send again"
                let sum = 28.0 + 35.0
                self.subtitle.stringValue = String(
                    format: "Verified · combined %.1f MB/s (%.1f× single lane)", sum, sum / 28.0,
                )
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.4
                    ctx.allowsImplicitAnimation = true
                    self.glass.tintColor = NSColor.systemGreen.withAlphaComponent(0.20)
                }
            }
        }
        timer.fire()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w: CGFloat = 420
        let h: CGFloat = 420
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Place it top-centre so the user can't miss it.
        let origin = NSPoint(x: screen.midX - w / 2, y: screen.maxY - h - 60)
        window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = "HyperSend — Liquid Glass demo"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let backdrop = BackdropView(frame: root.bounds)
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)

        let card = GlassCardView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: w - 40),
            card.heightAnchor.constraint(equalToConstant: h - 80),
        ])
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Report geometry so the agent can screenshot just this window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let f = self.window.frame
            let screenH = NSScreen.main?.frame.height ?? 900
            let top = screenH - (f.origin.y + f.height)
            let line = "RECT=\(Int(f.origin.x)),\(Int(top)),\(Int(f.width)),\(Int(f.height))\n"
            try? line.write(toFile: "/tmp/hs_glass_rect.txt", atomically: true, encoding: .utf8)
            var found = 0
            var interactive = 0
            func walk(_ v: NSView) {
                if let g = v as? NSGlassEffectView {
                    found += 1
                    if #available(macOS 27.0, *), g.effectIsInteractive { interactive += 1 }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            print("GLASS_VIEWS=\(found) INTERACTIVE=\(interactive)")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
