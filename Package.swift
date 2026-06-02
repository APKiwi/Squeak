// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "G502Battery",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HIDPPKit",
            path: "Sources/HIDPPKit"
        ),
        .executableTarget(
            name: "G502Battery",
            dependencies: ["HIDPPKit"],
            path: "Sources/G502Battery"
        ),
        // Plain CLI for debugging the HID++ layer without the SwiftUI launch path.
        .executableTarget(
            name: "g502probe",
            dependencies: ["HIDPPKit"],
            path: "Sources/g502probe"
        ),
    ]
)
