// swift-tools-version:5.9
//
// Lets Xcode open HyperSend as a first-class project: full indexing, jump-to-def,
// macro expansion and SwiftUI Previews, with no .xcodeproj to keep in sync.
//
// This is for *development* in Xcode. ./build.sh remains the canonical build —
// it is what produces the signed HyperSend.app bundle.

import PackageDescription

let package = Package(
    name: "HyperSend",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HyperSend",
            path: "Sources"
        )
    ]
)
