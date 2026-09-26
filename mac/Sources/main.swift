import AppKit
import Foundation

// Entry point. Three modes:
//
//   HyperSend                          → the app
//   HyperSend --send FILE [options]    → headless transfer
//   HyperSend --receive DIR [options]  → headless receiver
//
// The headless modes exist so the engine can be tested against the Node
// reference implementation on loopback, and so the app is scriptable.

let argv = CommandLine.arguments

if let index = argv.firstIndex(of: "--receive"), index + 1 < argv.count {
    runHeadlessReceive(destination: argv[index + 1])
} else if let index = argv.firstIndex(of: "--send"), index + 1 < argv.count {
    runHeadlessSend(fileArguments: argv, from: index + 1)
} else if argv.contains("--help") || argv.contains("-h") {
    printUsageAndExit()
} else {
    runGUI()
}

func argumentValue(_ name: String) -> String? {
    guard let index = argv.firstIndex(of: name), index + 1 < argv.count else { return nil }
    return argv[index + 1]
}

func argumentValues(_ name: String) -> [String] {
    var values: [String] = []
    for (index, value) in argv.enumerated() where value == name && index + 1 < argv.count {
        values.append(argv[index + 1])
    }
    return values
}

func printUsageAndExit() -> Never {
    print("""
    HyperSend — multipath file transfer

    Usage:
      HyperSend                                   launch the app
      HyperSend --send ITEM... [options]          send files and/or folders
      HyperSend --receive DIR [options]           act as a receiver

    Folders are walked recursively and arrive with their structure intact.

    Send options:
      --to HOST             receiver address (otherwise discovered by beacon)
      --port N              receiver control port (default 44010)
      --data-port N         force the primary lane onto this data port
      --extra HOST:PORT     add a lane (repeatable) — this is the multipath part
      --usb                 shorthand: adb-forward the USB cable and add it as a lane
      --streams N           sockets per lane (default 2)

    Receive options:
      --port N              control port (default 44010)
      --data-port N         fixed data port (default 44012)
    """)
    exit(0)
}

// MARK: - Headless receive

func runHeadlessReceive(destination: String) -> Never {
    let destDir = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)
    let controlPort = UInt16(argumentValue("--port") ?? "") ?? Proto.controlPort
    let dataPort = UInt16(argumentValue("--data-port") ?? "") ?? Proto.usbDataPort

    let engine = ReceiveEngine(
        destDir: destDir,
        controlPort: controlPort,
        dataPort: dataPort,
        hooks: ReceiveEngine.Hooks(
            accept: { path, size in
                print("· incoming \(path) \(formattedBytes(size))")
                return true
            },
            progress: { name, done, total in
                let fraction = total > 0 ? Double(done) / Double(total) : 1
                let line = String(format: "\r %@ [%@] %.1f%%  %@ / %@        ",
                                  name,
                                  String(repeating: "=", count: Int(fraction * 24)).padding(toLength: 24, withPad: " ", startingAt: 0),
                                  fraction * 100,
                                  formattedBytes(done),
                                  formattedBytes(total))
                FileHandle.standardError.write(Data(line.utf8))
            },
            finished: { file in
                let digest = (try? sha256File(URL(fileURLWithPath: file.path))) ?? "?"
                print("\n✓ \(file.name) verified · \(formattedBytes(file.size)) · sha256 \(digest.prefix(12))…")
            },
            log: { print("· \($0)") },
        ),
    )

    do {
        try engine.start()
    } catch {
        FileHandle.standardError.write(Data("receiver failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print("receiving into \(destDir.path) · control :\(controlPort) · data :\(dataPort)")
    while true {
        Thread.sleep(forTimeInterval: 0.5)
    }
}

// MARK: - Headless send

func runHeadlessSend(fileArguments: [String], from index: Int) -> Never {
    let inputs = fileArguments[index...]
        .prefix { !$0.hasPrefix("--") }
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    guard !inputs.isEmpty else {
        FileHandle.standardError.write(Data("nothing to send — see --help\n".utf8))
        exit(2)
    }

    let sources: [SendSource]
    do {
        sources = try collectSendSources(from: inputs)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(2)
    }
    let files = sources.map(\.url)
    let paths = sources.map(\.relativePath)

    let controlPort = UInt16(argumentValue("--port") ?? "") ?? Proto.controlPort
    let forcedDataPort = UInt16(argumentValue("--data-port") ?? "")

    var resolvedHost = argumentValue("--to")
    if resolvedHost == nil {
        print("scanning for a HyperSend receiver…")
        guard let found = sniffPeer(timeout: 6) else {
            FileHandle.standardError.write(Data("no receiver found — pass --to <ip>\n".utf8))
            exit(1)
        }
        print("found \(found.name) at \(found.host)")
        resolvedHost = found.host
    }
    guard let host = resolvedHost else { exit(1) }

    var lanes: [Lane] = [Lane(label: "wifi", host: host, port: forcedDataPort)]

    // The tunnel's local port is separate from the phone's data port so this
    // Mac can hold 44012 for its own receiver at the same time.
    if argv.contains("--usb") || argumentValue("--usb-port") != nil {
        let usbPort = UInt16(argumentValue("--usb-port") ?? "") ?? Proto.usbLocalPort
        if ADBBridge.ensureForward(localPort: usbPort, remotePort: Proto.usbDataPort) {
            lanes.append(Lane(label: "usb", host: "127.0.0.1", port: usbPort))
        } else {
            FileHandle.standardError.write(Data("could not open the USB tunnel; continuing without it\n".utf8))
        }
    }

    for (offset, spec) in argumentValues("--extra").enumerated() {
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let extraPort = UInt16(parts[1]) else {
            FileHandle.standardError.write(Data("ignoring malformed --extra \(spec)\n".utf8))
            continue
        }
        lanes.append(Lane(label: "extra\(offset + 1)", host: String(parts[0]), port: extraPort))
    }

    let streams = max(1, Int(argumentValue("--streams") ?? "") ?? 2)
    print("sending \(files.count) file(s) to \(host) over \(lanes.map(\.label).joined(separator: " + "))")

    let engine = SendEngine()
    var line = ""
    do {
        let summary = try engine.send(
            files: files,
            paths: paths,
            primary: lanes[0],
            extraLanes: Array(lanes.dropFirst()),
            controlPort: controlPort,
            socketsPerLane: streams,
            progress: { progress in
                var text = String(format: " %@  %@ / %@  %@",
                                  progress.fileName,
                                  formattedBytes(progress.bytesDone),
                                  formattedBytes(progress.bytesTotal),
                                  formattedRate(progress.bytesPerSec))
                for (label, report) in progress.lanes.sorted(by: { $0.key < $1.key }) {
                    text += String(format: "   %@ %@", label, formattedRate(report.bytesPerSec))
                }
                guard text != line else { return }
                line = text
                FileHandle.standardError.write(Data(("\r" + text + "        ").utf8))
            },
            log: { print("\n· \($0)") },
        )
        print("")
        print(String(format: "done · %@ in %@ · %@",
                     formattedBytes(summary.bytes),
                     formattedDuration(summary.seconds),
                     formattedRate(summary.bytesPerSec)))
        for (label, report) in summary.lanes.sorted(by: { $0.key < $1.key }) {
            print("  \(label): \(formattedBytes(report.bytes)) · \(formattedRate(report.bytesPerSec)) · \(report.chunks) chunks")
        }
        print("RESULT \(String(format: "%.2f", summary.bytesPerSec / 1_000_000)) MB/s")
        exit(0)
    } catch {
        print("")
        FileHandle.standardError.write(Data("failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - GUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("didFinishLaunching: entering")
        NSApp.setActivationPolicy(.regular)

        // Defaults must land before the model reads any preference.
        Pref.registerDefaults()
        AppearancePref.apply(UserDefaults.standard.string(forKey: Pref.appearance) ?? "system")
        MenuBarItem.shared.setVisible(UserDefaults.standard.bool(forKey: Pref.showMenuBarIcon))

        let controller = AppWindowController()
        LaunchTrace.mark("didFinishLaunching: controller built")
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        LaunchTrace.mark("didFinishLaunching: window ordered front")

        AppModel.shared.start()
        LaunchTrace.mark("didFinishLaunching: model started")

        // Testing hook: lets a headless run bring the Settings window up so it
        // can be captured without driving the menu bar. Checked as a preference
        // too, because `open HyperSend.app` is the only way to launch the app
        // reliably and it cannot pass environment variables on every OS build.
        let openSettings = ProcessInfo.processInfo.environment["HS_OPEN_SETTINGS"] == "1"
            || UserDefaults.standard.bool(forKey: "hs.openSettingsOnLaunch")
        if openSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                SettingsWindowController.shared.present()
            }
        }

        // Self-report so a headless shell can confirm the window really came up
        // (screencapture needs Screen Recording permission we may not have).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let model = AppModel.shared
            print("HYPERSEND_UP window=\(Int(controller.window?.frame.width ?? 0))x\(Int(controller.window?.frame.height ?? 0))"
                + " receiver=\(model.receiverReady)"
                + " usb=\(model.usbLaneReady)"
                + " peers=\(model.peers.count)")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

enum MenuBuilder {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About HyperSend", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide HyperSend", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit HyperSend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        // The menu bar is AppKit, so these target an AppKit object rather than
        // the SwiftUI window. Same code paths as the in-window buttons.
        fileMenu.addItem(MenuActions.shared.item(
            "Send Files…", #selector(MenuActions.sendFiles(_:)), "o",
        ))
        fileMenu.addItem(MenuActions.shared.item(
            "Add Device by IP…", #selector(MenuActions.addDevice(_:)), "n",
        ))
        fileMenu.addItem(.separator())
        fileMenu.addItem(MenuActions.shared.item(
            "Show Receive Folder", #selector(MenuActions.revealFolder(_:)), "r",
        ))
        fileMenu.addItem(MenuActions.shared.item(
            "Settings…", #selector(MenuActions.openSettings(_:)), ",",
        ))
        fileItem.submenu = fileMenu

        // Edit, with its actions pointing at the responder chain: without it
        // the Add-Device field and the device-name field have no ⌘C/⌘V/⌘X, and
        // the app fails the basic macOS text-editing contract.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // A standard Window menu: miniaturise, zoom, and the window list, so
        // ⌘M and the ⌘` cycle behave the way every other app does.
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help doubles as a required App Review item and the escape hatch for
        // discovery problems: two clicks to the repo, one to the log folder.
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(MenuActions.shared.item(
            "HyperSend Help", #selector(MenuActions.openHelp(_:)), "?",
        ))
        helpMenu.addItem(MenuActions.shared.item(
            "Report an Issue", #selector(MenuActions.reportIssue(_:)), "",
        ))
        helpMenu.addItem(.separator())
        helpMenu.addItem(MenuActions.shared.item(
            "Show Receive Folder", #selector(MenuActions.revealFolder(_:)), "",
        ))
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApplication.shared.mainMenu = main
    }
}

func runGUI() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    MenuBuilder.install()
    app.run()
}
