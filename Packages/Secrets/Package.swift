// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Secrets",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Secrets", targets: ["Secrets"]),
        .executable(name: "SecretsSmoke", targets: ["SecretsSmoke"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "Secrets",
            dependencies: ["Core"],
            path: "Sources/Secrets",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "SecretsSmoke",
            dependencies: ["Secrets", "Core"],
            path: "Sources/SecretsSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "SecretsTests",
            dependencies: ["Secrets"],
            path: "Tests/SecretsTests"
        )
    ]
)
