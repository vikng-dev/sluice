// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sluice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SluiceCore", path: "Sources/Core"),
        .target(name: "SluiceProviders", dependencies: ["SluiceCore"], path: "Sources/Providers"),
        .executableTarget(name: "SluiceApp", dependencies: ["SluiceProviders"], path: "Sources/App"),
        .executableTarget(name: "sluice", dependencies: ["SluiceProviders"], path: "Sources/CLI"),
        .testTarget(name: "CoreTests", dependencies: ["SluiceCore", "SluiceProviders"], path: "Tests/CoreTests"),
    ]
)
