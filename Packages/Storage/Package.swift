// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Storage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Storage", targets: ["Storage"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "Storage",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Storage",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: [
                "Storage",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/StorageTests"
        )
    ]
)
