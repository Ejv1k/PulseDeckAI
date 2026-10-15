// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PulseDeckAI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "PulseDeckAI",
            targets: ["PulseDeckAI"]
        ),
        .library(
            name: "PulseDeckCore",
            targets: ["PulseDeckCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PulseDeckCore",
            dependencies: [],
            path: "Sources/PulseDeckCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "PulseDeckAI",
            dependencies: [
                "PulseDeckCore"
            ],
            path: "Sources/PulseDeckAI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "PulseDeckCoreTests",
            dependencies: [
                "PulseDeckCore"
            ],
            path: "Tests/PulseDeckCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
