// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AI", targets: ["AI"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "AI",
            dependencies: ["Core"],
            path: "Sources/AI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "AITests",
            dependencies: ["AI"],
            path: "Tests/AITests"
        )
    ]
)
