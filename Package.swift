// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceInboxWatch",
    platforms: [.macOS(.v15), .watchOS(.v10)],
    products: [
        .executable(name: "codex-watch-bridge", targets: ["CodexWatchBridgeCLI"]),
        .executable(name: "codex-compatibility-smoke", targets: ["CodexCompatibilitySmokeCLI"]),
        .executable(name: "watch-device-preflight", targets: ["WatchDevicePreflightCLI"]),
        .executable(name: "watch-simulator-selector", targets: ["WatchSimulatorSelectorCLI"]),
        .library(name: "CodexBridgeShared", targets: ["CodexBridgeShared"]),
        .library(name: "CodexBridgeDelivery", targets: ["CodexBridgeDelivery"]),
        .library(name: "CodexBridgeService", targets: ["CodexBridgeService"]),
        .library(name: "CodexWatchCore", targets: ["CodexWatchCore"]),
        .library(name: "CodexAppServerProtocol", targets: ["CodexAppServerProtocol"]),
        .library(name: "CodexAppServerClient", targets: ["CodexAppServerClient"]),
        .library(name: "WatchDeviceReadiness", targets: ["WatchDeviceReadiness"]),
        .library(name: "WatchSimulatorSelection", targets: ["WatchSimulatorSelection"]),
    ],
    targets: [
        .target(name: "CodexBridgeShared"),
        .target(name: "CodexBridgeDelivery", dependencies: ["CodexBridgeShared"]),
        .target(
            name: "CodexBridgeService",
            dependencies: [
                "CodexBridgeShared",
                "CodexBridgeDelivery",
                "CodexAppServerClient",
                "CodexAppServerProtocol",
            ]
        ),
        .target(name: "CodexWatchCore", dependencies: ["CodexBridgeShared"]),
        .target(name: "CodexAppServerProtocol"),
        .target(name: "CodexAppServerClient", dependencies: ["CodexAppServerProtocol"]),
        .target(name: "WatchDeviceReadiness"),
        .target(name: "WatchSimulatorSelection"),
        .executableTarget(
            name: "CodexWatchBridgeCLI",
            dependencies: [
                "CodexBridgeService",
                "CodexBridgeDelivery",
                "CodexBridgeShared",
                "CodexWatchCore",
            ]
        ),
        .executableTarget(
            name: "CodexCompatibilitySmokeCLI",
            dependencies: ["CodexAppServerClient"]
        ),
        .executableTarget(
            name: "WatchDevicePreflightCLI",
            dependencies: ["WatchDeviceReadiness", "CodexAppServerClient"]
        ),
        .executableTarget(
            name: "WatchSimulatorSelectorCLI",
            dependencies: ["WatchSimulatorSelection", "CodexAppServerClient"]
        ),
        .testTarget(name: "CodexAppServerProtocolTests", dependencies: ["CodexAppServerProtocol"]),
        .testTarget(name: "CodexBridgeSharedTests", dependencies: ["CodexBridgeShared"]),
        .testTarget(
            name: "CodexBridgeDeliveryTests",
            dependencies: ["CodexBridgeDelivery", "CodexBridgeShared"]
        ),
        .testTarget(
            name: "CodexBridgeServiceTests",
            dependencies: [
                "CodexBridgeService",
                "CodexBridgeShared",
                "CodexAppServerProtocol",
            ]
        ),
        .testTarget(
            name: "CodexWatchBridgeCLITests",
            dependencies: ["CodexWatchBridgeCLI"]
        ),
        .testTarget(
            name: "CodexWatchCoreTests",
            dependencies: ["CodexWatchCore", "CodexBridgeShared"]
        ),
        .testTarget(
            name: "CodexAppServerClientTests",
            dependencies: ["CodexAppServerClient", "CodexAppServerProtocol"]
        ),
        .testTarget(
            name: "CodexCompatibilitySmokeCLITests",
            dependencies: ["CodexCompatibilitySmokeCLI", "CodexAppServerClient"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "CodexAppServerClient",
                "CodexAppServerProtocol",
                "CodexBridgeDelivery",
                "CodexBridgeService",
                "CodexBridgeShared",
                "CodexWatchCore",
            ]
        ),
        .testTarget(
            name: "WatchDeviceReadinessTests",
            dependencies: ["WatchDeviceReadiness"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WatchDevicePreflightCLITests",
            dependencies: ["WatchDevicePreflightCLI", "WatchDeviceReadiness"]
        ),
        .testTarget(
            name: "WatchSimulatorSelectionTests",
            dependencies: ["WatchSimulatorSelection"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WatchSimulatorSelectorCLITests",
            dependencies: ["WatchSimulatorSelectorCLI", "WatchSimulatorSelection"]
        ),
    ]
)
