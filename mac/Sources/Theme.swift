import Foundation

// Launch tracing.
//
// A GUI app that fails while building its window does it silently — no stdout,
// no crash, just a live process and no window. That cost us an afternoon twice,
// so the tracer stays.
//
//   HS_LAUNCH_TRACE=1 ./HyperSend.app/Contents/MacOS/HyperSend
//   tail -f /tmp/hypersend-launch.log
//
// The design tokens (spacing, colours, radii) now live in the SwiftUI `UI` enum
// in Sources/UI/HyperSendView.swift, where the views can read them directly.
enum LaunchTrace {
    static let enabled = ProcessInfo.processInfo.environment["HS_LAUNCH_TRACE"] == "1"
    private static let path = "/tmp/hypersend-launch.log"

    static func mark(_ stage: String) {
        guard enabled else { return }
        let line = Data("[launch] \(stage)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }
}
