// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AI", targets: ["AI"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Storage"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "AI",
            dependencies: ["Core", "Storage"],
            path: "Sources/AI",
            resources: [
                .process("Prompts")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "AITests",
            dependencies: ["AI", "Storage"],
            path: "Tests/AITests"
        ),
        .executableTarget(
            name: "ClassifierSmoke",
            dependencies: ["AI", "Core"],
            path: "Sources/ClassifierSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "RuleEngineSmoke",
            dependencies: [
                "AI", "Core", "Storage",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/RuleEngineSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "PrivacySmoke",
            dependencies: ["AI", "Core"],
            path: "Sources/PrivacySmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)
