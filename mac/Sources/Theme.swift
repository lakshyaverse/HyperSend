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
// The design tokens (type, icons, radii, spacing) live in the SwiftUI `UI` enum
// in Sources/UI/Tokens.swift, where the views can read them directly.
/// Canonical outbound links.
///
/// One place to change, so a placeholder host can never be shipped in an About
/// screen again — the previous build had `https://github.com` as its feedback
/// link, which looks finished and goes nowhere.
enum AppLinks {
    static let repository = URL(string: "https://github.com/lakshyaverse/HyperSend")!
    static let issues = repository.appendingPathComponent("issues")
}

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
