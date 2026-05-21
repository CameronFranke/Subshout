// swift-tools-version: 5.9
//
// SwiftPM build for the subshout macOS app.
//
// Why SwiftPM and not an .xcodeproj?  See ../TODO.md "design notes".  Short
// version: an .xcodeproj is binary, agent-hostile, and we'd need a CLI build
// for CI anyway.  Cameron can still open this Package.swift in Xcode.
//
// `swift build -c release` produces an unbundled binary at
// `.build/release/SubShout`.  The build script under `../scripts/build-app.sh`
// turns that into a real `subshout.app` bundle (with Info.plist, Resources/,
// and — for production — the embedded `shout-daemon` Python env).

import PackageDescription

let package = Package(
    name: "SubShout",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SubShout",
            path: "Sources/SubShout"
        ),
        .testTarget(
            name: "SubShoutTests",
            dependencies: ["SubShout"],
            path: "Tests/SubShoutTests"
        ),
    ]
)
