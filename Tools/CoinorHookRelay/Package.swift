// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoinorHookRelay",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CoinorHookRelayCore",
            targets: ["CoinorHookRelayCore"]
        ),
        .executable(
            name: "coinor-hook-relay",
            targets: ["CoinorHookRelay"]
        ),
    ],
    targets: [
        .target(name: "CoinorHookRelayPOSIX"),
        .target(
            name: "CoinorHookRelayCore",
            dependencies: ["CoinorHookRelayPOSIX"]
        ),
        .executableTarget(
            name: "CoinorHookRelay",
            dependencies: ["CoinorHookRelayCore"]
        ),
        .testTarget(
            name: "CoinorHookRelayCoreTests",
            dependencies: ["CoinorHookRelayCore"]
        ),
    ]
)
