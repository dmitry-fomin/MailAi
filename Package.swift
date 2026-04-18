// swift-tools-version: 6.0
//
// Корневой мета-пакет: агрегирует все SPM-модули MailAi, чтобы можно было
// собирать всё разом (`swift build` из корня репо) без Xcode.
// Для запуска приложения как .app target используется Xcode-проект
// (см. project.yml и Scripts/xcodegen.sh).

import PackageDescription

let package = Package(
    name: "MailAi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MailAiAll", targets: ["MailAiAll"])
    ],
    dependencies: [
        .package(path: "Packages/Core"),
        .package(path: "Packages/Secrets"),
        .package(path: "Packages/Storage"),
        .package(path: "Packages/MailTransport"),
        .package(path: "Packages/AI"),
        .package(path: "Packages/UI"),
        .package(path: "Packages/MockData"),
        .package(path: "Packages/AppShell")
    ],
    targets: [
        .target(
            name: "MailAiAll",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "Secrets", package: "Secrets"),
                .product(name: "Storage", package: "Storage"),
                .product(name: "MailTransport", package: "MailTransport"),
                .product(name: "AI", package: "AI"),
                .product(name: "UI", package: "UI"),
                .product(name: "MockData", package: "MockData"),
                .product(name: "AppShell", package: "AppShell")
            ],
            path: "Sources/MailAiAll"
        )
    ]
)
