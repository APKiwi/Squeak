// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squeak",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HIDPPKit",
            path: "Sources/HIDPPKit"
        ),
        .executableTarget(
            name: "Squeak",
            dependencies: ["HIDPPKit"],
            path: "Sources/Squeak"
        ),
        // Plain CLI for debugging the HID++ layer without the SwiftUI launch path.
        .executableTarget(
            name: "squeakprobe",
            dependencies: ["HIDPPKit"],
            path: "Sources/squeakprobe"
        ),
        .testTarget(
            name: "HIDPPKitTests",
            dependencies: ["HIDPPKit"],
            path: "Tests/HIDPPKitTests"
        ),
    ]
)
