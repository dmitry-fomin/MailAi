// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Storage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Storage", targets: ["Storage"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "Storage",
            dependencies: ["Core"],
            path: "Sources/Storage",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage"],
            path: "Tests/StorageTests"
        )
    ]
)
