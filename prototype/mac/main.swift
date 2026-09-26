import AppKit
import QuartzCore

// HyperSend — native macOS prototype.
//
// Design rules (learned from Apple's own apps):
//  · Glass is CHROME ONLY: toolbar, sidebar, floating controls. Never a big
//    novelty card on top of a gradient.
//  · Content lives on calm surfaces; hairline separators, no heavy borders.
//  · SF Pro hierarchy: 13pt semibold titles, 12pt secondary labels.
//  · One accent colour (system blue), used sparingly.
//  · 8pt rhythm, 16–20pt insets, 10–16pt corner radii.
//  · Monospaced digits for numbers only.

let kSidebarWidth: CGFloat = 224
let kHeaderHeight: CGFloat = 52
let kRowHeight: CGFloat = 56

// MARK: - Palette & metrics

enum Palette {
    static let accent = NSColor.controlAccentColor
    static let hairline = NSColor.separatorColor.withAlphaComponent(0.6)
}

func hairline() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = Palette.hairline.cgColor
    v.translatesAutoresizingMaskIntoConstraints = false
    v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return v
}

/// Rounded, tinted icon tile — like Mail's per-row colour chips.
final class IconTile: NSView {
    private let imageView = NSImageView()

    init(symbol: String, tint: NSColor, size: CGFloat = 28) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor

        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
        imageView.contentTintColor = tint
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Label helper with HIG-consistent styling.
func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

// MARK: - Glass button (chrome)

/// Circular glass toolbar button — interactive glass, hover response.
final class GlassIconButton: NSView {
    private let glass = NSGlassEffectView()
    private let button = NSButton()
    private var tracking: NSTrackingArea?

    init(symbol: String, tooltip: String, action: Selector, target: AnyObject) {
        super.init(frame: .zero)
        wantsLayer = true

        glass.style = .regular
        glass.cornerRadius = 15
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        addSubview(glass)

        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = button

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        button.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            button.animator().contentTintColor = .labelColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            button.animator().contentTintColor = .secondaryLabelColor
        }
    }
}

/// Prominent capsule action button (accent filled), sized like Mail's primary.
final class AccentButton: NSButton {
    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .rounded
        controlSize = .large
        font = .systemFont(ofSize: 13, weight: .semibold)
        keyEquivalent = "\r"
        wantsLayer = true
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Sidebar

final class SidebarRow: NSView {
    private let icon: IconTile
    private let title: NSTextField
    private let count: NSTextField
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private var hovering = false

    init(symbol: String, tint: NSColor, title: String, count: String?) {
        self.icon = IconTile(symbol: symbol, tint: tint, size: 22)
        self.title = label(title, size: 13, weight: .regular, color: .labelColor)
        self.count = label(count ?? "", size: 12, weight: .regular, color: .tertiaryLabelColor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        addSubview(icon)
        addSubview(self.title)
        addSubview(self.count)
        icon.translatesAutoresizingMaskIntoConstraints = false
        self.title.translatesAutoresizingMaskIntoConstraints = false
        self.count.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            self.title.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            self.count.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.title.trailingAnchor.constraint(lessThanOrEqualTo: self.count.leadingAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Palette.accent.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { onSelect?() }
}

final class SidebarView: NSView {
    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
    private var rows: [SidebarRow] = []
    var onSelect: ((Int) -> Void)?
    private var selection = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addSection("Devices")
        addRow(symbol: "iphone.gen3", tint: .systemBlue, title: "CMF Phone 1", count: "connected")
        addRow(symbol: "laptopcomputer", tint: .systemPurple, title: "MacBook Pro", count: "this Mac")
        addSection("Recent")
        addRow(symbol: "arrow.down.circle.fill", tint: .systemGreen, title: "Received", count: "12")
        addRow(symbol: "arrow.up.circle.fill", tint: .systemOrange, title: "Sent", count: "34")
        addSection("")
        addRow(symbol: "gearshape.fill", tint: .systemGray, title: "Settings", count: nil)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func addSection(_ title: String) {
        let l = label(title.uppercased(), size: 11, weight: .semibold, color: .tertiaryLabelColor)
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            l.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 14),
            l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
            wrap.heightAnchor.constraint(equalToConstant: 28),
        ])
        stack.addArrangedSubview(wrap)
        wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addRow(symbol: String, tint: NSColor, title: String, count: String?) {
        let row = SidebarRow(symbol: symbol, tint: tint, title: title, count: count)
        let index = rows.count
        row.onSelect = { [weak self] in
            self?.selection = index
            self?.updateSelection()
            self?.onSelect?(index)
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rows.append(row)
    }

    private func updateSelection() {
        for (i, r) in rows.enumerated() { r.isSelected = (i == selection) }
    }
}

// MARK: - Transfer row

final class TransferRow: NSView {
    private let icon: IconTile
    private let name: NSTextField
    private let detail: NSTextField
    private let time: NSTextField
    private let progress = NSView()
    private let progressFill = NSView()
    private var fraction: CGFloat
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var selected = false

    init(symbol: String, tint: NSColor, name: String, detail: String, time: String, fraction: CGFloat) {
        self.icon = IconTile(symbol: symbol, tint: tint, size: 26)
        self.name = label(name, size: 13, weight: .semibold, color: .labelColor)
        self.detail = label(detail, size: 12, weight: .regular, color: .secondaryLabelColor)
        self.time = label(time, size: 12, weight: .regular, color: .tertiaryLabelColor)
        self.fraction = fraction
        super.init(frame: .zero)
        wantsLayer = true

        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        progress.layer?.cornerRadius = 2
        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = Palette.accent.cgColor
        progressFill.layer?.cornerRadius = 2
        progress.addSubview(progressFill)

        [icon, self.name, self.detail, self.time, progress].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        self.time.alignment = .right
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: kRowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            self.name.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            self.time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            self.time.centerYAnchor.constraint(equalTo: self.name.centerYAnchor),
            self.time.leadingAnchor.constraint(greaterThanOrEqualTo: self.name.trailingAnchor, constant: 8),
            self.detail.leadingAnchor.constraint(equalTo: self.name.leadingAnchor),
            self.detail.topAnchor.constraint(equalTo: self.name.bottomAnchor, constant: 2),
            self.detail.trailingAnchor.constraint(lessThanOrEqualTo: self.time.leadingAnchor, constant: -8),
            progress.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progress.heightAnchor.constraint(equalToConstant: 4),
            progress.topAnchor.constraint(equalTo: self.detail.bottomAnchor, constant: 6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        progressFill.frame = NSRect(x: 0, y: 0, width: progress.bounds.width * fraction, height: 4)
    }

    func setFraction(_ f: CGFloat, detailText: String) {
        fraction = f
        detail.stringValue = detailText
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            progressFill.animator().frame = NSRect(x: 0, y: 0, width: progress.bounds.width * f, height: 4)
        }
    }

    func setSelected(_ on: Bool) { selected = on; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            Palette.accent.withAlphaComponent(0.14).setFill()
            bounds.fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.03).setFill()
            bounds.fill()
        }
        // Hairline bottom separator, inset like Mail's.
        Palette.hairline.setFill()
        NSRect(x: 16, y: 0, width: bounds.width - 16, height: 1).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
}

// MARK: - Lane readout (detail pane)

final class LaneCard: NSView {
    private let glass = NSGlassEffectView()
    private let icon: IconTile
    private let name: NSTextField
    private let rate: NSTextField
    private let bar = NSView()
    private let barFill = NSView()
    private let accent: NSColor
    private var tracking: NSTrackingArea?
    private var fraction: CGFloat = 0

    init(symbol: String, tint: NSColor, title: String) {
        self.icon = IconTile(symbol: symbol, tint: tint, size: 24)
        self.name = label(title, size: 12, weight: .medium, color: .labelColor)
        self.rate = label("—", size: 12, weight: .medium, color: .secondaryLabelColor)
        self.accent = tint
        super.init(frame: .zero)
        wantsLayer = true

        glass.style = .regular
        glass.cornerRadius = 12
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        addSubview(glass)

        rate.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        rate.alignment = .right

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        bar.layer?.cornerRadius = 2
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = tint.cgColor
        barFill.layer?.cornerRadius = 2
        bar.addSubview(barFill)

        let host = NSView()
        [icon, name, rate, bar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview($0)
        }
        glass.contentView = host
        NSLayoutConstraint.activate([
            host.heightAnchor.constraint(equalToConstant: 58),
            icon.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            rate.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            rate.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            rate.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            bar.heightAnchor.constraint(equalToConstant: 4),
            bar.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        barFill.frame = NSRect(x: 0, y: 0, width: bar.bounds.width * fraction, height: 4)
    }

    func update(fraction f: CGFloat, rateText: String, active: Bool) {
        fraction = f
        rate.stringValue = rateText
        rate.textColor = active ? accent : .secondaryLabelColor
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.allowsImplicitAnimation = true
            barFill.animator().frame = NSRect(x: 0, y: 0, width: bar.bounds.width * f, height: 4)
        }
    }
}

// MARK: - Main window controller

final class RootView: NSView {
    let sidebar = SidebarView()
    let listStack = NSStackView()
    let titleLabel = label("Transfers", size: 13, weight: .semibold, color: .labelColor)
    let subLabel = label("2 devices · ready", size: 11, weight: .regular, color: .tertiaryLabelColor)
    let wifiLane = LaneCard(symbol: "wifi", tint: .systemBlue, title: "Wi-Fi  ·  hotspot lane")
    let usbLane = LaneCard(symbol: "cable.connector", tint: .systemGreen, title: "USB  ·  cable lane")
    let totalLabel = label("—", size: 28, weight: .semibold, color: .labelColor)
    let totalCaption = label("combined throughput", size: 11, weight: .regular, color: .tertiaryLabelColor)
    let statusLabel = label("Ready to send", size: 11, weight: .regular, color: .secondaryLabelColor)
    var rows: [TransferRow] = []
    var sendButton: AccentButton!
    private var timer: Timer?
    private var tick = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // ── Sidebar ──────────────────────────────────────────────────────
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebar)

        // ── Vertical divider (hairline, like Mail) ───────────────────────
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.hairline.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)


        // ── Header (glass chrome) ────────────────────────────────────────
        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let headerGlass = NSGlassEffectView()
        headerGlass.style = .clear
        headerGlass.cornerRadius = 0
        if #available(macOS 27.0, *) { headerGlass.effectIsInteractive = true }
        headerGlass.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerGlass, positioned: .below, relativeTo: nil)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(buttonRow)

        let gear = GlassIconButton(symbol: "gearshape", tooltip: "Settings", action: #selector(noop), target: self)
        let info = GlassIconButton(symbol: "info.circle", tooltip: "About", action: #selector(noop), target: self)
        buttonRow.addArrangedSubview(gear)
        buttonRow.addArrangedSubview(info)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(subLabel)

        // ── Transfer list ────────────────────────────────────────────────
        let listScroll = NSScrollView()
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listScroll)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let listDoc = NSView()
        listDoc.addSubview(listStack)
        listScroll.documentView = listDoc
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listDoc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDoc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listDoc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDoc.bottomAnchor),
        ])

        // ── Detail pane ──────────────────────────────────────────────────
        let detail = NSView()
        detail.wantsLayer = true
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)

        let detailDivider = NSView()
        detailDivider.wantsLayer = true
        detailDivider.layer?.backgroundColor = Palette.hairline.cgColor
        detailDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailDivider)

        let detailTitle = label("Live lanes", size: 11, weight: .semibold, color: .tertiaryLabelColor)
        let detailFile = label("hs-multi.bin", size: 13, weight: .semibold, color: .labelColor)
        let detailMeta = label("300 MB · SHA-256 verified", size: 11, weight: .regular, color: .secondaryLabelColor)

        totalLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        totalCaption.alignment = .left

        sendButton = AccentButton(title: "Send file", target: self, action: #selector(startDemo))

        let numbers = NSStackView(views: [totalLabel, totalCaption])
        numbers.orientation = .vertical
        numbers.alignment = .leading
        numbers.spacing = 0

        let detailStack = NSStackView(views: [detailTitle, detailFile, detailMeta, wifiLane, usbLane, numbers, sendButton])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 12
        detailStack.setCustomSpacing(2, after: detailTitle)
        detailStack.setCustomSpacing(18, after: detailMeta)
        // NOTE: custom spacing must be applied to views that are *directly* arranged
        // in this stack. `totalLabel` lives inside `numbers`, so ask for spacing
        // after the nested stack instead — otherwise AppKit's layout engine spins.
        detailStack.setCustomSpacing(4, after: numbers)
        detailStack.setCustomSpacing(18, after: usbLane)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(detailStack)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            // sidebar + divider
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: kSidebarWidth),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // header spans list + detail
            header.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: kHeaderHeight),
            headerGlass.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerGlass.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerGlass.topAnchor.constraint(equalTo: header.topAnchor),
            headerGlass.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 9),
            subLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 0),
            buttonRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            buttonRow.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            // list
            listScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            listScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            listScroll.widthAnchor.constraint(equalToConstant: 380),
            listDoc.widthAnchor.constraint(equalTo: listScroll.widthAnchor),

            // detail
            detailDivider.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            detailDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            detailDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailDivider.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: detailDivider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: header.bottomAnchor),
            detail.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            detailStack.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 20),
            detailStack.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -20),
            detailStack.topAnchor.constraint(equalTo: detail.topAnchor, constant: 18),
            wifiLane.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            usbLane.widthAnchor.constraint(equalTo: detailStack.widthAnchor),

            // status bar
            statusLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 18),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Real measured rows (from the phone tests earlier).
        addRow(symbol: "film", tint: .systemIndigo, name: "hs-multi.bin", detail: "300 MB · Wi-Fi + USB · verified", time: "50.9 MB/s", fraction: 1.0)
        addRow(symbol: "waveform", tint: .systemTeal, name: "hs-single.bin", detail: "300 MB · Wi-Fi only · verified", time: "27.7 MB/s", fraction: 1.0)
        addRow(symbol: "doc.zipper", tint: .systemOrange, name: "hs-live.bin", detail: "200 MB · verified", time: "37.6 MB/s", fraction: 1.0)
        addRow(symbol: "photo.on.rectangle", tint: .systemPink, name: "screenshot.png", detail: "2.4 MB · queued", time: "—", fraction: 0)

        sidebar.onSelect = { [weak self] _ in self?.flashStatus("Device selected") }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func addRow(symbol: String, tint: NSColor, name: String, detail: String, time: String, fraction: CGFloat) {
        let row = TransferRow(symbol: symbol, tint: tint, name: name, detail: detail, time: time, fraction: fraction)
        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        rows.append(row)
    }

    @objc private func noop() {}

    @objc private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    @objc func startDemo() {
        timer?.invalidate()
        tick = 0
        sendButton.title = "Sending…"
        sendButton.isEnabled = false
        statusLabel.stringValue = "Transferring over 2 lanes · SHA-256 verifying"
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] t in
            guard let self else { return }
            self.tick += 1
            let p = min(1.0, Double(self.tick) / 26.0)
            // Measured reality: Wi-Fi ~28 MB/s, USB ~35 MB/s, combined ~51 MB/s.
            let wifi = 28 * (0.94 + 0.06 * Double.random(in: 0...1))
            let usb = 35 * (0.94 + 0.06 * Double.random(in: 0...1))
            self.wifiLane.update(fraction: CGFloat(p), rateText: String(format: "%.1f MB/s", wifi), active: true)
            self.usbLane.update(fraction: CGFloat(p), rateText: String(format: "%.1f MB/s", usb), active: true)
            let combined = (wifi + usb) * (p < 1 ? 0.86 : 1.0) // slight overlap while ramping
            self.totalLabel.stringValue = String(format: "%.1f MB/s", combined)
            self.totalCaption.stringValue = "combined throughput · 1.8× single lane"
            if p >= 1 {
                t.invalidate()
                self.sendButton.title = "Send again"
                self.sendButton.isEnabled = true
                self.statusLabel.stringValue = "Transfer complete — SHA-256 verified · 300 MB"
                self.rows[0].setFraction(1.0, detailText: "300 MB · Wi-Fi + USB · verified")
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w: CGFloat = 1060
        let h: CGFloat = 640
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = "HyperSend"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 900, height: 560)
        window.center()

        window.contentView = RootView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let f = self.window.frame
            let screenH = NSScreen.main?.frame.height ?? 900
            let top = screenH - (f.origin.y + f.height)
            let line = "RECT=\(Int(f.origin.x)),\(Int(top)),\(Int(f.width)),\(Int(f.height))\n"
            try? line.write(toFile: "/tmp/hs_glass_rect.txt", atomically: true, encoding: .utf8)
            print("HYPER_SEND_UI_UP window=\(Int(f.width))x\(Int(f.height))")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
MenuBuilder.install()
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - Menu (⌘Q etc.)

enum MenuBuilder {
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About HyperSend", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide HyperSend", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit HyperSend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = main
    }
}
