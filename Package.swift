// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cadence", targets: ["Cadence"]),
        .library(name: "LaunchCore", targets: ["LaunchCore"])
    ],
    targets: [
        .target(name: "LaunchCore"),
        .executableTarget(name: "Cadence", dependencies: ["LaunchCore"]),
        .testTarget(name: "LaunchCoreTests", dependencies: ["LaunchCore"]),
        .testTarget(name: "CadenceTests", dependencies: ["Cadence", "LaunchCore"])
    ],
    swiftLanguageModes: [.v5]
)
