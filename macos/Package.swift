// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirBridgeCore", targets: ["AirBridgeCore"]),
        .executable(name: "AirBridge", targets: ["AirBridge"]),
        .executable(name: "airbridge-cli", targets: ["airbridge-cli"]),
    ],
    targets: [
        // Protocol, crypto, transport and transfer engine. No UI code.
        .target(name: "AirBridgeCore"),
        // SwiftUI application.
        .executableTarget(name: "AirBridge", dependencies: ["AirBridgeCore"]),
        // Headless sender/receiver used for interop tests and benchmarks.
        .executableTarget(name: "airbridge-cli", dependencies: ["AirBridgeCore"]),
        .testTarget(
            name: "AirBridgeCoreTests",
            dependencies: ["AirBridgeCore"],
            resources: [.copy("Vectors")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
