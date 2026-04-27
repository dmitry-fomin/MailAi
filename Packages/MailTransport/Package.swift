// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailTransport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MailTransport", targets: ["MailTransport"]),
        .executable(name: "IMAPSmokeCLI", targets: ["IMAPSmokeCLI"]),
        .executable(name: "IMAPPerfSmoke", targets: ["IMAPPerfSmoke"]),
        .executable(name: "IMAPSessionSmoke", targets: ["IMAPSessionSmoke"]),
        .executable(name: "SMTPSmoke", targets: ["SMTPSmoke"]),
        .executable(name: "MIMESmoke", targets: ["MIMESmoke"]),
        .executable(name: "SMTPProviderSmoke", targets: ["SMTPProviderSmoke"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Storage"),
        .package(path: "../Secrets"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.27.0")
    ],
    targets: [
        .target(
            name: "MailTransport",
            dependencies: [
                "Core", "Storage", "Secrets",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            path: "Sources/MailTransport",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "IMAPSmokeCLI",
            dependencies: [
                "MailTransport", "Core"
            ],
            path: "Sources/IMAPSmokeCLI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "IMAPPerfSmoke",
            dependencies: [
                "MailTransport", "Core",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/IMAPPerfSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "IMAPSessionSmoke",
            dependencies: [
                "MailTransport"
            ],
            path: "Sources/IMAPSessionSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "MailTransportTests",
            dependencies: [
                "MailTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Tests/MailTransportTests"
        ),
        .executableTarget(
            name: "SMTPSmoke",
            dependencies: [
                "MailTransport", "Core",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            path: "Sources/SMTPSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "MIMESmoke",
            dependencies: [
                "MailTransport"
            ],
            path: "Sources/MIMESmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "SMTPProviderSmoke",
            dependencies: [
                "MailTransport", "Core", "Secrets"
            ],
            path: "Sources/SMTPProviderSmoke",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)
