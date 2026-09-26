import AppKit
import SwiftUI

// The app's one window: a SwiftUI split view hosted in AppKit.
//
// Hosting it ourselves (rather than a SwiftUI `WindowGroup`) keeps the AppKit
// menu bar, activation policy and lifecycle exactly as they were, so the engine,
// the CLI modes and the menus are untouched.
//
// `fullSizeContentView` + a transparent title bar is what lets a
// NavigationSplitView's sidebar run up under the traffic lights the way Apple's
// own apps do — the split view handles its own insets from there.
final class AppWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingView(rootView: HyperSendView(model: .shared))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = "HyperSend"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 940, height: 620)
        window.contentView = hosting
        window.setFrameAutosaveName("HyperSendMain")

        LaunchTrace.mark("AppWindow: built")
        self.init(window: window)
    }
}
