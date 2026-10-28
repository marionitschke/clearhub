// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClearHub",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClearHubCore"),
        .executableTarget(name: "ClearHub", dependencies: ["ClearHubCore"]),
        .testTarget(name: "ClearHubCoreTests", dependencies: ["ClearHubCore"]),
    ]
)
