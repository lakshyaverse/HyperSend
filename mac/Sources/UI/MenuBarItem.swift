import AppKit

// Optional menu bar presence.
//
// The menu is rebuilt every time it opens, so the status line is always current
// without a timer running in the background.
final class MenuBarItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarItem()

    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        visible ? install() : remove()
    }

    private func install() {
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "HyperSend")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        item = statusItem
    }

    private func remove() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let model = AppModel.shared
        let status: String
        if let active = model.activeTransfer, active.status == .active {
            status = "\(active.name) · \(formattedRate(active.bytesPerSec))"
        } else if model.receiverReady {
            status = "Ready · \(model.usbLaneReady ? "Wi-Fi + USB" : "Wi-Fi")"
        } else {
            status = "Idle"
        }

        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(MenuActions.shared.item("Send Files…", #selector(MenuActions.sendFiles(_:)), ""))
        menu.addItem(MenuActions.shared.item("Show Window", #selector(MenuActions.showWindow(_:)), ""))
        menu.addItem(MenuActions.shared.item("Show Receive Folder", #selector(MenuActions.revealFolder(_:)), ""))
        menu.addItem(MenuActions.shared.item("Settings…", #selector(MenuActions.openSettings(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(MenuActions.shared.item("Quit HyperSend", #selector(MenuActions.quit(_:)), "q"))
    }
}
