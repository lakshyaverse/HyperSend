import AppKit
import SwiftUI

// The app's one window: a SwiftUI view hosted in AppKit.
//
// Hosting it ourselves (rather than a SwiftUI `WindowGroup`) keeps the AppKit
// menu bar, activation policy and lifecycle exactly as they were, so the engine,
// the CLI modes and the menus are untouched.
//
// An ordinary titled window, deliberately. The previous build needed
// `fullSizeContentView` and a transparent title bar so a NavigationSplitView
// sidebar could run under the traffic lights; there is no sidebar now, and a
// standard title bar is what a utility window is supposed to look like.
final class AppWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingView(rootView: HyperSendView(model: .shared))

        // A utility window, sized like one. It was 1080x700 for a three-column
        // dashboard; a single column of devices and transfers needs no more
        // width than a long file name.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "HyperSend"
        window.minSize = NSSize(width: 560, height: 440)
        window.contentView = hosting
        // A new name on purpose. The previous layout saved a 1080x700 frame
        // under "HyperSendMain", and restoring it would drop this one-column
        // design into a window twice the size it was drawn for.
        window.setFrameAutosaveName("HyperSendMain2")

        LaunchTrace.mark("AppWindow: built")
        self.init(window: window)
    }
}
