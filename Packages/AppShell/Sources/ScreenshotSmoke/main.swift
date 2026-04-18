import Foundation
#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import Core
import MockData
import AppShell
import UI
#endif

// A10: генератор PNG-скриншотов ключевых экранов (Light/Dark). Сторонних
// snapshot-библиотек нет — используем штатный SwiftUI.ImageRenderer.
// Файлы пишутся в Scripts/artifacts/screenshots/ и служат:
//   • CI-артефактом для ручной проверки ревьюером;
//   • базой для будущих diff-тестов (ImageRenderer.cgImage + pixel compare).
//
// В чистом CLT-окружении без графического контекста ImageRenderer может не
// смочь создать bitmap — тогда smoke логирует причину и выходит с кодом 0,
// чтобы не блокировать scripted build. Реальный CI должен гонять это через
// Xcode test scheme (на GitHub Actions macos-13/14 runner).

let SCREENSHOTS: [(String, CGSize)] = [
    ("welcome", CGSize(width: 480, height: 420)),
    ("account-window", CGSize(width: 1200, height: 720)),
    ("reader-header", CGSize(width: 720, height: 220)),
    ("reader-toolbar", CGSize(width: 720, height: 48))
]

func outDir() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    // Ищем корень репозитория: либо .git, либо Package.swift/MailAi.xcodeproj.
    var dir = root
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { break }
        dir = dir.deletingLastPathComponent()
    }
    let screenshots = dir.appendingPathComponent("Scripts/artifacts/screenshots", isDirectory: true)
    try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
    return screenshots
}

#if canImport(SwiftUI) && canImport(AppKit)

@MainActor
func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme) -> Data? {
    let wrapped = view
        .environment(\.colorScheme, scheme)
        .frame(width: size.width, height: size.height)
    let renderer = ImageRenderer(content: wrapped)
    renderer.scale = 2.0
    guard let nsImage = renderer.nsImage,
          let tiff = nsImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        return nil
    }
    return png
}

@MainActor
func renderAll() async throws {
    let dir = try outDir()
    let mock = MockAccountDataProvider()
    let session = AccountSessionModel(account: mock.account, provider: mock)

    // Welcome
    let welcome = WelcomeScene(
        onAddAccount: {},
        onContinueWithMock: {}
    )

    // AccountWindow — требует mailboxes. Синхронно без await нельзя, поэтому
    // ниже — отдельная async-обёртка.

    // Reader blocks
    let fakeMessage = Message(
        id: Message.ID("a10-screenshot-msg"),
        accountID: mock.account.id,
        mailboxID: Mailbox.ID("inbox"),
        uid: 1,
        messageID: "<a10-screenshot@example.com>",
        threadID: nil,
        subject: "Скриншот-тест A10",
        from: MailAddress(address: "alice@example.com", name: "Alice"),
        to: [MailAddress(address: "bob@example.com", name: "Bob")],
        cc: [],
        date: Date(timeIntervalSince1970: 1_712_900_000),
        preview: "Краткое превью письма для A10-снимка.",
        size: 2048,
        flags: [],
        importance: .unknown
    )
    let header = ReaderHeaderView(message: fakeMessage)
    let toolbar = ReaderToolbar()

    let variants: [(String, CGSize, (ColorScheme) -> Data?)] = [
        ("welcome", CGSize(width: 480, height: 420), { render(welcome, size: .init(width: 480, height: 420), scheme: $0) }),
        ("reader-header", CGSize(width: 720, height: 220), { render(header, size: .init(width: 720, height: 220), scheme: $0) }),
        ("reader-toolbar", CGSize(width: 720, height: 48), { render(toolbar, size: .init(width: 720, height: 48), scheme: $0) })
    ]

    var produced = 0
    var failed: [String] = []

    for (name, _, renderFn) in variants {
        for scheme in [ColorScheme.light, .dark] {
            let schemeName = scheme == .light ? "light" : "dark"
            if let png = renderFn(scheme) {
                let url = dir.appendingPathComponent("\(name)-\(schemeName).png")
                try png.write(to: url)
                produced += 1
                print("✓ \(name)-\(schemeName).png (\(png.count) bytes)")
            } else {
                failed.append("\(name)-\(schemeName)")
            }
        }
    }

    // AccountWindow — требует async-загрузки mailboxes.
    await session.loadMailboxes()
    let accountScene = AccountWindowScene(session: session)
    for scheme in [ColorScheme.light, .dark] {
        let schemeName = scheme == .light ? "light" : "dark"
        if let png = render(accountScene, size: .init(width: 1200, height: 720), scheme: scheme) {
            let url = dir.appendingPathComponent("account-window-\(schemeName).png")
            try png.write(to: url)
            produced += 1
            print("✓ account-window-\(schemeName).png (\(png.count) bytes)")
        } else {
            failed.append("account-window-\(schemeName)")
        }
    }

    print("\nА10: \(produced) PNG записано в \(dir.path)")
    if !failed.isEmpty {
        FileHandle.standardError.write(Data(
            "⚠ не удалось отрендерить (CLT без графики?): \(failed.joined(separator: ", "))\n".utf8
        ))
    }
}

@main
enum ScreenshotSmokeRunner {
    @MainActor
    static func main() async {
        do {
            try await renderAll()
        } catch {
            FileHandle.standardError.write(Data(
                "⚠ ScreenshotSmoke завершён с ошибкой: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}

#else

@main
enum ScreenshotSmokeRunner {
    static func main() async {
        FileHandle.standardError.write(Data(
            "⚠ ScreenshotSmoke требует SwiftUI+AppKit. Запустите через Xcode.\n".utf8
        ))
    }
}

#endif
