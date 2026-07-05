// swift-tools-version: 5.9
// abgui — a native SwiftUI macOS front-end that drives the EMBEDDED abctl as its backend.
// Zero external dependencies: shell out to abctl, decode its JSON with Foundation, render
// with SwiftUI. See ../docs/abgui-design.md.
import PackageDescription

let package = Package(
    name: "abgui",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "abgui",
            path: "Sources/abgui"
        ),
        .testTarget(
            name: "abguiTests",
            dependencies: ["abgui"],
            path: "Tests/abguiTests"
        ),
    ]
)
