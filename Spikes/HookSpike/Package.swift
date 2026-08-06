// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HookSpike",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "HookSpikeHarnessCore",
            targets: ["HookSpikeHarnessCore"]
        ),
        .executable(
            name: "hook-spike-harness",
            targets: ["HookSpikeHarness"]
        ),
    ],
    dependencies: [
        .package(path: "../../Tools/CoinorHookRelay"),
    ],
    targets: [
        .target(
            name: "HookSpikeHarnessCore",
            dependencies: [
                .product(
                    name: "CoinorHookRelayCore",
                    package: "CoinorHookRelay"
                ),
            ]
        ),
        .executableTarget(
            name: "HookSpikeHarness",
            dependencies: ["HookSpikeHarnessCore"]
        ),
        .testTarget(
            name: "HookSpikeHarnessTests",
            dependencies: [
                "HookSpikeHarnessCore",
                .product(
                    name: "CoinorHookRelayCore",
                    package: "CoinorHookRelay"
                ),
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
