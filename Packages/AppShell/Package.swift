// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppShell",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppShell", targets: ["AppShell"]),
        .executable(name: "AppShellSmoke", targets: ["AppShellSmoke"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../UI"),
        .package(path: "../MockData"),
        .package(path: "../Storage"),
        .package(path: "../Secrets"),
        .package(path: "../MailTransport"),
        .package(path: "../AI")
    ],
    targets: [
        .target(
            name: "AppShell",
            dependencies: ["Core", "UI", "MockData", "Storage", "Secrets", "MailTransport", "AI"],
            path: "Sources/AppShell",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "AppShellSmoke",
            dependencies: ["AppShell", "Core", "MockData"],
            path: "Sources/AppShellSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "Core", "MockData"],
            path: "Tests/AppShellTests"
        )
    ]
)
