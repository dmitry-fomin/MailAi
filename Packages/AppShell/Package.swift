// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppShell",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppShell", targets: ["AppShell"]),
        .executable(name: "AppShellSmoke", targets: ["AppShellSmoke"]),
        .executable(name: "IntegrationSmoke", targets: ["IntegrationSmoke"]),
        .executable(name: "ScreenshotSmoke", targets: ["ScreenshotSmoke"]),
        .executable(name: "LiveFlowSmoke", targets: ["LiveFlowSmoke"]),
        .executable(name: "ActionsSmoke", targets: ["ActionsSmoke"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../UI"),
        .package(path: "../MockData"),
        .package(path: "../Storage"),
        .package(path: "../Secrets"),
        .package(path: "../MailTransport"),
        .package(path: "../AI"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0")
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
        .executableTarget(
            name: "IntegrationSmoke",
            dependencies: [
                "AppShell", "Core", "Storage", "Secrets", "MailTransport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/IntegrationSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "ScreenshotSmoke",
            dependencies: [
                "AppShell", "Core", "MockData", "UI"
            ],
            path: "Sources/ScreenshotSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "LiveFlowSmoke",
            dependencies: [
                "AppShell", "Core", "Storage", "Secrets", "MailTransport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/LiveFlowSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "ActionsSmoke",
            dependencies: [
                "AppShell", "Core", "Storage", "Secrets", "MailTransport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/ActionsSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "AppShellTests",
            dependencies: [
                "AppShell", "Core", "MockData", "Storage", "AI",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/AppShellTests"
        )
    ]
)
