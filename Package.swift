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
            name: "PulseDeckAtomics",
            path: "Sources/PulseDeckAtomics",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .define("PULSEDECK_USE_ACCELERATE", to: "1", .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "PulseDeckCore",
            dependencies: ["PulseDeckAtomics"],
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
                "PulseDeckCore",
                "PulseDeckAtomics",
                "PulseDeckAI"
            ],
            path: "Tests/PulseDeckCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
