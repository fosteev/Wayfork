// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WayforkCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WayforkCore", targets: ["WayforkCore"])
    ],
    targets: [
        .target(name: "WayforkCore"),
        .testTarget(name: "WayforkCoreTests", dependencies: ["WayforkCore"]),
    ],
    swiftLanguageModes: [.v6]
)
