// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WayforkCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WayforkCore", targets: ["WayforkCore"]),
        .library(name: "WayforkDaemonCore", targets: ["WayforkDaemonCore"]),
    ],
    targets: [
        .target(name: "WayforkCore"),
        // Daemon logic that needs no privileges: process plumbing, management protocol,
        // reconcile planning. The `WayforkDaemon` executable is a thin shell around it.
        .target(name: "WayforkDaemonCore", dependencies: ["WayforkCore"]),
        // Developer tool: builds a RuntimePlan JSON from configs on the command line so the
        // daemon can be exercised with `WayforkDaemon --dev-apply` before the app exists.
        .executableTarget(name: "wayforkctl", dependencies: ["WayforkCore"]),
        // Test inputs and golden outputs live in the repo-level fixtures/ directory, shared
        // with the Windows client's Dart and Go tests.
        .testTarget(name: "WayforkCoreTests", dependencies: ["WayforkCore"]),
        .testTarget(name: "WayforkDaemonCoreTests", dependencies: ["WayforkDaemonCore"]),
    ],
    swiftLanguageModes: [.v6]
)
