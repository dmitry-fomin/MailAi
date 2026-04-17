// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailTransport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MailTransport", targets: ["MailTransport"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Storage"),
        .package(path: "../Secrets")
    ],
    targets: [
        .target(
            name: "MailTransport",
            dependencies: ["Core", "Storage", "Secrets"],
            path: "Sources/MailTransport",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "MailTransportTests",
            dependencies: ["MailTransport"],
            path: "Tests/MailTransportTests"
        )
    ]
)
