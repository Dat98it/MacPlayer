// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacPlayer",
    // macOS 15: AVAssetExportSession.export(to:as:) (async) and states(updateInterval:) need it;
    // the callback API is deprecated in the macOS 27 SDK.
    platforms: [.macOS(.v15)],
    targets: [
        // Every decision: rational time, selections, playlists, safe-save planning, project files,
        // export planning, subtitles. Foundation only, and no direct file I/O: it goes through `FileSystem`.
        .target(name: "MacPlayerCore", path: "Sources/MacPlayerCore"),
        // AVFoundation: probing, thumbnails, exporting (fast cut and exact cut), media generation for tests.
        .target(name: "MacPlayerMedia", dependencies: ["MacPlayerCore"], path: "Sources/MacPlayerMedia"),
        // The app: a thin AppKit/SwiftUI layer that wires Core and Media together.
        .executableTarget(name: "MacPlayer", dependencies: ["MacPlayerCore", "MacPlayerMedia"], path: "Sources/MacPlayer"),
        // Command line tool for media spikes and verification. Never modifies the files it reads.
        .executableTarget(name: "macplayer-probe", dependencies: ["MacPlayerCore", "MacPlayerMedia"], path: "Sources/macplayer-probe"),
        .testTarget(name: "MacPlayerCoreTests", dependencies: ["MacPlayerCore"], path: "Tests/MacPlayerCoreTests"),
        .testTarget(name: "MacPlayerMediaTests", dependencies: ["MacPlayerCore", "MacPlayerMedia"], path: "Tests/MacPlayerMediaTests"),
    ],
    swiftLanguageVersions: [.v5]
)
