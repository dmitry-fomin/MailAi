// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MockData",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MockData", targets: ["MockData"]),
        .executable(name: "MockDataSmoke", targets: ["MockDataSmoke"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],

    targets: [
        .target(
            name: "MockData",
            dependencies: ["Core"],
            path: "Sources/MockData",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "MockDataSmoke",
            dependencies: ["MockData", "Core"],
            path: "Sources/MockDataSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "MockDataTests",
            dependencies: ["MockData"],
            path: "Tests/MockDataTests"
        )
    ]
)
