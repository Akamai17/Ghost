// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ghost",
    platforms: [.macOS(.v14)],
    targets: [
        // Engine: platform-agnostic element model + matching. No UI, no AppKit assumptions.
        .target(name: "GuideKit", path: "Sources/GuideKit"),
        // macOS plumbing: accessibility tree, hotkey, overlay, HUD.
        .target(name: "PlatformMac", dependencies: ["GuideKit"], path: "Sources/PlatformMac"),
        // The app shell.
        .executableTarget(name: "Ghost", dependencies: ["GuideKit", "PlatformMac"], path: "Sources/Ghost"),
    ]
)
