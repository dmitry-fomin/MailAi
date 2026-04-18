// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .executable(name: "CoreSmoke", targets: ["CoreSmoke"])
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "CoreSmoke",
            dependencies: ["Core"],
            path: "Sources/CoreSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
