// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sluice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SluiceCore", path: "Sources/Core"),
        .executableTarget(name: "SluiceApp", dependencies: ["SluiceCore"], path: "Sources/App"),
        .executableTarget(name: "sluice", dependencies: ["SluiceCore"], path: "Sources/CLI"),
    ]
)
