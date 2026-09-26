import AppKit

// Menu targets. The menu bar is AppKit, so its items need an AppKit object in
// the responder chain — the SwiftUI window cannot receive them. Keeping them in
// one tiny object means the File menu and the in-window buttons call exactly the
// same code paths.
final class MenuActions: NSObject {
    static let shared = MenuActions()

    /// A File-menu item already wired to this object.
    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc func sendFiles(_ sender: Any?) {
        AppModel.shared.chooseAndSend()
    }

    @objc func addDevice(_ sender: Any?) {
        presentAddDevice(problem: nil)
    }

    /// Asks for an address, and on nonsense asks again *saying why*. The first
    /// version accepted any non-empty string and put an unreachable device in
    /// the sidebar with no explanation.
    private func presentAddDevice(problem: String?) {
        let alert = NSAlert()
        alert.messageText = "Add a device"
        let instructions = "Enter the other device's IP address. Use this when the beacon cannot reach it."
        alert.informativeText = problem.map { "\($0)\n\n\(instructions)" } ?? instructions
        alert.alertStyle = problem == nil ? .informational : .warning
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "192.168.1.20"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppModel.isConnectableHost(host) else {
            presentAddDevice(problem: "\u{201C}\(host)\u{201D} is not an IP address or host name.")
            return
        }
        AppModel.shared.addPeerManually(host: host)
    }

    @objc func revealFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([AppModel.shared.receiveDirectory])
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppLinks.repository)
    }

    @objc func reportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(AppLinks.issues)
    }

    @objc func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "HyperSend" {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
