#!/usr/bin/env swift
// Prints the main window ID of an app by name, for `screencapture -l<ID>`.
// (CGWindowListCreateImage is obsoleted; the CLI does the capture instead.)
//
//   xcrun swift tools/window-id.swift Xcode
//   screencapture -x -l $(xcrun swift tools/window-id.swift Xcode) /tmp/out.png

import CoreGraphics
import Foundation

let appName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Xcode"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]

guard let target = list.first(where: {
    ($0[kCGWindowOwnerName as String] as? String) == appName &&
    ((($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double) ?? 0) > 400
}), let id = target[kCGWindowNumber as String] as? Int else {
    fatalError("no \(appName) window found")
}
print(id)
