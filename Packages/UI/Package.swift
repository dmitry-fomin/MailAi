// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UI", targets: ["UI"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "UI",
            dependencies: ["Core"],
            path: "Sources/UI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ],
            linkerSettings: [
                .linkedFramework("QuickLookUI")
            ]
        ),
        .testTarget(
            name: "UITests",
            dependencies: ["UI"],
            path: "Tests/UITests"
        ),
        .executableTarget(
            name: "StatusNotificationsSmoke",
            dependencies: [],
            path: "Sources/StatusNotificationsSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)
