import AppKit
import SwiftUI

// The app's one window: a SwiftUI view hosted in AppKit.
//
// Hosting it ourselves (rather than a SwiftUI `WindowGroup`) keeps the AppKit
// menu bar, activation policy and lifecycle exactly as they were, so the engine,
// the CLI modes and the menus are untouched.
//
// The design is the Icon Composer look: a pastel scene that runs edge to edge
// with glass panels floating on it, so the title bar is folded away and the
// scene extends under the traffic lights. `fullSizeContentView` with a hidden
// title achieves that; the window stays draggable via its title bar area and
// fully resizable.
final class AppWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingView(rootView: HyperSendView(model: .shared))

        // The reference window is a wide three-column layout: sidebar, hero,
        // inspector. 900x600 is its comfortable resting size.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = "HyperSend"
        window.titlebarAppearsTransparent = true
        // The title text stays out of the way; the scene provides the identity.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 760, height: 480)
        window.contentView = hosting
        // Fresh autosave name: the previous layouts saved frames under other
        // keys, and restoring one would mis-size this three-column design.
        window.setFrameAutosaveName("HyperSendScene")

        LaunchTrace.mark("AppWindow: built")
        self.init(window: window)
    }
}
