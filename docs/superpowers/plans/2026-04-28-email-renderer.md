# Email Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить заглушку `HTMLSanitizer.plainText()` в `ReaderBodyView` на полноценный рендер HTML-писем через WKWebView с кешем, quote-collapsing, dark mode и блокировкой трекеров.

**Architecture:** WKWebView в NSViewRepresentable-обёртке; HTML предобрабатывается Swift-актором (`HTMLPreprocessor`) — инжектирует CSP, схлопывает цитаты, проверяет dark mode поддержку. Обработанный HTML и бинарные вложения кешируются на диск через три Swift-актора (`MessageBodyCache`, `AttachmentCacheStore`, `CacheManager`). Inline-изображения (`cid:`) подаются через кастомный `WKURLSchemeHandler`. JS из контента письма отключён.

**Tech Stack:** SwiftUI, AppKit (NSViewRepresentable, NSViewController), WebKit (WKWebView, WKURLSchemeHandler), Foundation (FileManager, SHA-256 через CryptoKit), XCTest

**Spec:** `docs/superpowers/specs/2026-04-28-email-renderer-design.md`

---

## Структура файлов

**Создать:**
```
Packages/UI/Sources/UI/Reader/
  HTMLPreprocessor.swift       — actor, трансформации HTML
  MessageWebView.swift         — NSViewRepresentable + NSViewController + WKNavigationDelegate
  MailCIDSchemeHandler.swift   — NSObject + WKURLSchemeHandler

Packages/UI/Sources/UI/Cache/
  MessageBodyCache.swift       — actor, кеш обработанного HTML
  AttachmentCacheStore.swift   — actor, кеш бинарных вложений
  CacheManager.swift           — actor, LRU eviction, фасад для Settings

Packages/UI/Tests/UITests/
  HTMLPreprocessorTests.swift
  CacheTests.swift
```

**Изменить:**
```
Packages/UI/Sources/UI/ReaderBodyView.swift   — подключить MessageWebView
Packages/UI/Tests/UITests/PlaceholderTests.swift — удалить HTMLSanitizerTests
CLAUDE.md                                     — обновить политику кеша
```

---

## Task 1: HTMLPreprocessor

**Files:**
- Create: `Packages/UI/Sources/UI/Reader/HTMLPreprocessor.swift`
- Create: `Packages/UI/Tests/UITests/HTMLPreprocessorTests.swift`

- [ ] **Шаг 1.1: Написать падающие тесты**

```swift
// Packages/UI/Tests/UITests/HTMLPreprocessorTests.swift
#if canImport(XCTest)
import XCTest
@testable import UI

final class HTMLPreprocessorTests: XCTestCase {

    // MARK: - CSP

    func testInjectsCSPMetaTag() async {
        let result = await HTMLPreprocessor().process("<p>Hello</p>", blockExternalImages: true)
        XCTAssertTrue(result.html.contains("Content-Security-Policy"), "CSP meta tag missing")
        XCTAssertTrue(result.html.contains("script-src 'none'"), "script-src none missing")
    }

    // MARK: - External images

    func testBlocksExternalImagesInCSP() async {
        let html = #"<img src="https://example.com/pixel.png">"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: true)
        XCTAssertTrue(result.html.contains("img-src cid: data: 'self'"), "Should block external images in CSP")
        XCTAssertFalse(result.html.contains("img-src cid: data: 'self' https:"), "Should not allow https in CSP when blocking")
    }

    func testAllowsExternalImagesInCSPWhenNotBlocking() async {
        let html = #"<img src="https://example.com/pixel.png">"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("img-src cid: data: 'self' https:"), "Should allow https in CSP when not blocking")
    }

    func testDetectsExternalImages() async {
        let html = #"<img src="https://tracker.com/pixel.png">"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: true)
        XCTAssertTrue(result.hasExternalImages)
    }

    func testNoExternalImagesForCIDOnly() async {
        let html = #"<img src="cid:image001">"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: true)
        XCTAssertFalse(result.hasExternalImages)
    }

    // MARK: - Dark mode

    func testDetectsDarkModeSupport() async {
        let html = "<style>@media (prefers-color-scheme: dark) { body { background: black; } }</style>"
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.hasDarkModeSupport)
    }

    func testNoDarkModeSupportWhenAbsent() async {
        let result = await HTMLPreprocessor().process("<p>Hello</p>", blockExternalImages: false)
        XCTAssertFalse(result.hasDarkModeSupport)
    }

    // MARK: - Quote collapsing

    func testCollapsesGmailQuote() async {
        let html = #"<p>New message</p><div class="gmail_quote"><p>Quoted</p></div>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("<details"), "Gmail quote should be wrapped in details")
        XCTAssertTrue(result.html.contains("mail-quote"), "Should have mail-quote class")
        XCTAssertFalse(result.html.contains(#"class="gmail_quote""#), "Original class should be replaced")
    }

    func testCollapsesAppleMailQuote() async {
        let html = #"<p>Reply</p><blockquote type="cite"><p>Original</p></blockquote>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("<details"))
    }

    func testCollapsesOutlookQuote() async {
        let html = #"<p>Reply</p><div id="divRplyFwdMsg"><p>Original</p></div>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("<details"))
    }

    func testSummaryTextIsPreviousMessages() async {
        let html = #"<p>Hi</p><div class="gmail_quote"><p>Old</p></div>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("<summary>"))
    }

    // MARK: - Base styles

    func testInjectsViewportMeta() async {
        let result = await HTMLPreprocessor().process("<p>Hello</p>", blockExternalImages: false)
        XCTAssertTrue(result.html.contains("viewport"))
    }

    func testInjectsBaseStyles() async {
        let result = await HTMLPreprocessor().process("<p>Hello</p>", blockExternalImages: false)
        XCTAssertTrue(result.html.contains("max-width: 100%"))
    }

    // MARK: - HTML structure

    func testEnsuresHtmlHeadBodyStructure() async {
        let result = await HTMLPreprocessor().process("<p>Hello</p>", blockExternalImages: false)
        XCTAssertTrue(result.html.hasPrefix("<!DOCTYPE html>") || result.html.contains("<html"))
        XCTAssertTrue(result.html.contains("<head>") || result.html.contains("<head "))
        XCTAssertTrue(result.html.contains("<body>") || result.html.contains("<body "))
    }
}
#endif
```

- [ ] **Шаг 1.2: Убедиться что тесты падают**

```bash
swift test --package-path Packages/UI --filter HTMLPreprocessorTests 2>&1 | tail -5
```
Ожидаемый результат: compile error "cannot find type 'HTMLPreprocessor'"

- [ ] **Шаг 1.3: Создать HTMLPreprocessor.swift**

```swift
// Packages/UI/Sources/UI/Reader/HTMLPreprocessor.swift
import Foundation

public struct ProcessedEmail: Sendable {
    public let html: String
    public let hasDarkModeSupport: Bool
    public let hasExternalImages: Bool
}

public actor HTMLPreprocessor {
    public init() {}

    public func process(_ rawHTML: String, blockExternalImages: Bool) async -> ProcessedEmail {
        let hasDarkMode = detectDarkModeSupport(rawHTML)
        let hasExternal = detectExternalImages(rawHTML)
        var html = ensureStructure(rawHTML)
        html = injectHead(html, blockExternalImages: blockExternalImages)
        html = collapseQuotes(html)
        return ProcessedEmail(html: html, hasDarkModeSupport: hasDarkMode, hasExternalImages: hasExternal)
    }

    // MARK: - Detection

    private func detectDarkModeSupport(_ html: String) -> Bool {
        html.range(of: "prefers-color-scheme", options: .caseInsensitive) != nil
    }

    private func detectExternalImages(_ html: String) -> Bool {
        // Ищем img src с http:// или https://
        let pattern = #"<img[^>]+src\s*=\s*["']https?://"#
        return html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Structure

    private func ensureStructure(_ html: String) -> String {
        let lower = html.lowercased()
        if lower.contains("<html") {
            return html
        }
        return """
        <!DOCTYPE html>
        <html><head></head><body>
        \(html)
        </body></html>
        """
    }

    // MARK: - Head injection

    private func injectHead(_ html: String, blockExternalImages: Bool) -> String {
        let imgSrc = blockExternalImages
            ? "img-src cid: data: 'self'"
            : "img-src cid: data: 'self' https:"
        let injected = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; \(imgSrc)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        *{max-width:100%;box-sizing:border-box}
        body{word-wrap:break-word;overflow-wrap:break-word;margin:0;padding:0}
        img{height:auto}
        details.mail-quote{margin:8px 0;border-left:3px solid #ccc;padding-left:8px}
        details.mail-quote summary{cursor:pointer;color:#888;font-size:0.9em;padding:4px 0;user-select:none}
        </style>
        """
        // Вставляем после <head> или <head ...>
        if let range = html.range(of: "<head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: range, with: "<head>\n\(injected)")
        }
        if let range = html.range(of: #"<head\s[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(html[range])
            return html.replacingCharacters(in: range, with: "\(tag)\n\(injected)")
        }
        return html
    }

    // MARK: - Quote collapsing

    private func collapseQuotes(_ html: String) -> String {
        var result = html
        // Gmail
        result = wrapPattern(result, open: #"<div[^>]+class="[^"]*gmail_quote[^"]*""#, closeTag: "div")
        // Apple Mail
        result = wrapPattern(result, open: #"<blockquote[^>]+type="cite""#, closeTag: "blockquote")
        // Apple Mail div
        result = wrapPattern(result, open: #"<div[^>]+class="[^"]*AppleOriginalContents[^"]*""#, closeTag: "div")
        // Outlook
        result = wrapPattern(result, open: #"<div[^>]+id="x?_?divRplyFwdMsg""#, closeTag: "div")
        return result
    }

    private func wrapPattern(_ html: String, open openPattern: String, closeTag: String) -> String {
        guard let openRange = html.range(of: openPattern, options: [.regularExpression, .caseInsensitive]) else {
            return html
        }
        let openTag = String(html[openRange])
        // Найти соответствующий закрывающий тег (простой подход — первый </closeTag>)
        let afterOpen = html[openRange.upperBound...]
        let closeStr = "</\(closeTag)>"
        guard let closeRange = afterOpen.range(of: closeStr, options: .caseInsensitive) else {
            return html
        }
        let innerStart = openRange.upperBound
        let innerEnd = afterOpen.startIndex..<closeRange.lowerBound
        let inner = String(afterOpen[innerEnd])

        var result = html
        let fullRange = openRange.lowerBound..<afterOpen.index(closeRange.lowerBound, offsetBy: closeStr.count)
        let replacement = """
        <details class="mail-quote">\
        <summary>Предыдущие сообщения</summary>\
        \(openTag)\(inner)</\(closeTag)>\
        </details>
        """
        result.replaceSubrange(fullRange, with: replacement)
        return result
    }
}
```

- [ ] **Шаг 1.4: Запустить тесты**

```bash
swift test --package-path Packages/UI --filter HTMLPreprocessorTests 2>&1 | tail -20
```
Ожидаемый результат: все тесты зелёные.

- [ ] **Шаг 1.5: Коммит**

```bash
git add Packages/UI/Sources/UI/Reader/HTMLPreprocessor.swift \
        Packages/UI/Tests/UITests/HTMLPreprocessorTests.swift
git commit -m "feat(ui): HTMLPreprocessor — quote collapsing, CSP, dark mode, external images"
```

---

## Task 2: MessageBodyCache

**Files:**
- Create: `Packages/UI/Sources/UI/Cache/MessageBodyCache.swift`
- Create: `Packages/UI/Tests/UITests/CacheTests.swift` (первая часть)

- [ ] **Шаг 2.1: Написать падающие тесты**

```swift
// Packages/UI/Tests/UITests/CacheTests.swift
#if canImport(XCTest)
import XCTest
@testable import UI

final class MessageBodyCacheTests: XCTestCase {
    var cache: MessageBodyCache!
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        cache = MessageBodyCache(cacheDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testReadReturnNilForMiss() async throws {
        let result = await cache.read(messageID: "msg-001")
        XCTAssertNil(result)
    }

    func testWriteThenRead() async throws {
        let html = "<p>Hello world</p>"
        await cache.write(messageID: "msg-001", processedHTML: html)
        let result = await cache.read(messageID: "msg-001")
        XCTAssertEqual(result, html)
    }

    func testInvalidateRemovesEntry() async throws {
        await cache.write(messageID: "msg-001", processedHTML: "<p>test</p>")
        await cache.invalidate(messageID: "msg-001")
        let result = await cache.read(messageID: "msg-001")
        XCTAssertNil(result)
    }

    func testClearAllRemovesEverything() async throws {
        await cache.write(messageID: "msg-001", processedHTML: "<p>one</p>")
        await cache.write(messageID: "msg-002", processedHTML: "<p>two</p>")
        _ = await cache.clearAll()
        let r1 = await cache.read(messageID: "msg-001")
        let r2 = await cache.read(messageID: "msg-002")
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    func testClearAllReturnsByteCount() async throws {
        let html = "<p>Hello</p>"
        await cache.write(messageID: "msg-001", processedHTML: html)
        let freed = await cache.clearAll()
        XCTAssertGreaterThan(freed, 0)
    }

    func testTotalSizeReflectsWritten() async throws {
        let html = String(repeating: "x", count: 1000)
        await cache.write(messageID: "msg-001", processedHTML: html)
        let size = await cache.totalSize()
        XCTAssertGreaterThan(size, 500) // UTF-8, минимум 500 байт
    }
}
#endif
```

- [ ] **Шаг 2.2: Убедиться что тесты падают**

```bash
swift test --package-path Packages/UI --filter MessageBodyCacheTests 2>&1 | tail -5
```
Ожидаемый результат: compile error "cannot find type 'MessageBodyCache'"

- [ ] **Шаг 2.3: Создать MessageBodyCache.swift**

```swift
// Packages/UI/Sources/UI/Cache/MessageBodyCache.swift
import CryptoKit
import Foundation

public actor MessageBodyCache {
    private let bodiesDir: URL

    public init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.bodiesDir = dir.appendingPathComponent("bodies")
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.bodiesDir = caches.appendingPathComponent("MailAi/bodies")
        }
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
    }

    public func read(messageID: String) async -> String? {
        let url = fileURL(for: messageID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Обновляем atime через запись и чтение (FileManager не предоставляет setAttributes для atime напрямую)
        try? (url as NSURL).setResourceValue(Date(), forKey: .contentAccessDateKey)
        return String(data: data, encoding: .utf8)
    }

    public func write(messageID: String, processedHTML: String) async {
        let url = fileURL(for: messageID)
        try? processedHTML.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    public func invalidate(messageID: String) async {
        try? FileManager.default.removeItem(at: fileURL(for: messageID))
    }

    public func clearAll() async -> Int {
        let size = totalSizeSync()
        try? FileManager.default.removeItem(at: bodiesDir)
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
        return size
    }

    public func totalSize() async -> Int { totalSizeSync() }

    // MARK: - Internal (не async, вызывается внутри актора)

    func fileURL(for messageID: String) -> URL {
        let hash = SHA256.hash(data: Data(messageID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return bodiesDir.appendingPathComponent("\(hash).html")
    }

    func allFiles() -> [(url: URL, date: Date, messageIDHash: String)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: bodiesDir, includingPropertiesForKeys: [.contentAccessDateKey]
        ) else { return [] }
        return items.compactMap { url in
            let hash = url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? Date.distantPast
            return (url, date, hash)
        }
    }

    private func totalSizeSync() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: bodiesDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
```

> **Примечание:** `Package.swift` нужно добавить `CryptoKit` в `linkerSettings` или использовать встроенный CommonCrypto. CryptoKit доступен на macOS 10.15+, что совместимо с целевой платформой macOS 14.

- [ ] **Шаг 2.4: Запустить тесты**

```bash
swift test --package-path Packages/UI --filter MessageBodyCacheTests 2>&1 | tail -20
```
Ожидаемый результат: все тесты зелёные.

- [ ] **Шаг 2.5: Коммит**

```bash
git add Packages/UI/Sources/UI/Cache/MessageBodyCache.swift \
        Packages/UI/Tests/UITests/CacheTests.swift
git commit -m "feat(ui): MessageBodyCache — дисковый кеш обработанного HTML"
```

---

## Task 3: AttachmentCacheStore

**Files:**
- Modify: `Packages/UI/Tests/UITests/CacheTests.swift` (добавить класс)
- Create: `Packages/UI/Sources/UI/Cache/AttachmentCacheStore.swift`

- [ ] **Шаг 3.1: Дописать тесты**

Добавить в конец `CacheTests.swift` (перед финальным `#endif`):

```swift
final class AttachmentCacheStoreTests: XCTestCase {
    var store: AttachmentCacheStore!
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = AttachmentCacheStore(cacheDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testReadReturnNilForMiss() async throws {
        let result = await store.read(messageID: "msg-1", contentID: "img001")
        XCTAssertNil(result)
    }

    func testWriteThenRead() async throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header
        await store.write(messageID: "msg-1", contentID: "img001", data: data, mimeType: "image/png")
        let result = await store.read(messageID: "msg-1", contentID: "img001")
        XCTAssertEqual(result?.0, data)
        XCTAssertEqual(result?.1, "image/png")
    }

    func testClearAllRemovesFiles() async throws {
        let data = Data([0x01, 0x02])
        await store.write(messageID: "msg-1", contentID: "img001", data: data, mimeType: "image/jpeg")
        _ = await store.clearAll()
        let result = await store.read(messageID: "msg-1", contentID: "img001")
        XCTAssertNil(result)
    }

    func testMessageIDHashStoredInMeta() async throws {
        let data = Data([0x01])
        await store.write(messageID: "msg-abc", contentID: "img001", data: data, mimeType: "image/png")
        let files = await store.allFiles()
        XCTAssertTrue(files.contains { $0.messageIDHash == AttachmentCacheStore.sha256("msg-abc") })
    }
}
```

- [ ] **Шаг 3.2: Убедиться что тесты падают**

```bash
swift test --package-path Packages/UI --filter AttachmentCacheStoreTests 2>&1 | tail -5
```

- [ ] **Шаг 3.3: Создать AttachmentCacheStore.swift**

```swift
// Packages/UI/Sources/UI/Cache/AttachmentCacheStore.swift
import CryptoKit
import Foundation

struct AttachmentMeta: Codable {
    let mimeType: String
    let size: Int
    let messageIDHash: String
}

public actor AttachmentCacheStore {
    private let attachDir: URL

    public init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.attachDir = dir.appendingPathComponent("attachments")
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.attachDir = caches.appendingPathComponent("MailAi/attachments")
        }
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
    }

    public func read(messageID: String, contentID: String) async -> (Data, String)? {
        let binURL = binFileURL(messageID: messageID, contentID: contentID)
        let metaURL = metaFileURL(messageID: messageID, contentID: contentID)
        guard let data = try? Data(contentsOf: binURL),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(AttachmentMeta.self, from: metaData)
        else { return nil }
        try? (binURL as NSURL).setResourceValue(Date(), forKey: .contentAccessDateKey)
        return (data, meta.mimeType)
    }

    public func write(messageID: String, contentID: String, data: Data, mimeType: String) async {
        let binURL = binFileURL(messageID: messageID, contentID: contentID)
        let metaURL = metaFileURL(messageID: messageID, contentID: contentID)
        let meta = AttachmentMeta(
            mimeType: mimeType,
            size: data.count,
            messageIDHash: Self.sha256(messageID)
        )
        try? data.write(to: binURL, options: .atomic)
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    public func clearAll() async -> Int {
        let size = totalSizeSync()
        try? FileManager.default.removeItem(at: attachDir)
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        return size
    }

    public func totalSize() async -> Int { totalSizeSync() }

    // MARK: - Internal

    func allFiles() -> [(url: URL, date: Date, messageIDHash: String)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: attachDir,
            includingPropertiesForKeys: [.contentAccessDateKey]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "meta" }
            .compactMap { metaURL in
                guard let metaData = try? Data(contentsOf: metaURL),
                      let meta = try? JSONDecoder().decode(AttachmentMeta.self, from: metaData)
                else { return nil }
                let date = (try? metaURL.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
                return (metaURL, date, meta.messageIDHash)
            }
    }

    func deleteByMessageIDHash(_ messageIDHash: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: attachDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in items {
            guard url.pathExtension == "meta",
                  let metaData = try? Data(contentsOf: url),
                  let meta = try? JSONDecoder().decode(AttachmentMeta.self, from: metaData),
                  meta.messageIDHash == messageIDHash
            else { continue }
            try? FileManager.default.removeItem(at: url)
            let binURL = url.deletingPathExtension().appendingPathExtension("bin")
            try? FileManager.default.removeItem(at: binURL)
        }
    }

    static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func binFileURL(messageID: String, contentID: String) -> URL {
        let hash = Self.sha256(messageID + contentID)
        return attachDir.appendingPathComponent("\(hash).bin")
    }

    private func metaFileURL(messageID: String, contentID: String) -> URL {
        let hash = Self.sha256(messageID + contentID)
        return attachDir.appendingPathComponent("\(hash).meta")
    }

    private func totalSizeSync() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: attachDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
```

- [ ] **Шаг 3.4: Запустить тесты**

```bash
swift test --package-path Packages/UI --filter AttachmentCacheStoreTests 2>&1 | tail -20
```

- [ ] **Шаг 3.5: Коммит**

```bash
git add Packages/UI/Sources/UI/Cache/AttachmentCacheStore.swift \
        Packages/UI/Tests/UITests/CacheTests.swift
git commit -m "feat(ui): AttachmentCacheStore — дисковый кеш бинарных вложений"
```

---

## Task 4: CacheManager (LRU eviction)

**Files:**
- Create: `Packages/UI/Sources/UI/Cache/CacheManager.swift`
- Modify: `Packages/UI/Tests/UITests/CacheTests.swift` (добавить класс)

- [ ] **Шаг 4.1: Дописать тесты**

Добавить в конец `CacheTests.swift` перед `#endif`:

```swift
final class CacheManagerTests: XCTestCase {
    var manager: CacheManager!
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let bodyCache = MessageBodyCache(cacheDir: tmpDir)
        let attCache = AttachmentCacheStore(cacheDir: tmpDir)
        manager = CacheManager(bodyCache: bodyCache, attachmentCache: attCache, limitBytes: 500)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testTotalSizeIsZeroInitially() async throws {
        let size = await manager.totalSize()
        XCTAssertEqual(size, 0)
    }

    func testClearAllResetsSize() async throws {
        await manager.writeBody(messageID: "msg-1", processedHTML: String(repeating: "x", count: 600))
        await manager.clearAll()
        let size = await manager.totalSize()
        XCTAssertEqual(size, 0)
    }

    func testEvictsOldestWhenOverLimit() async throws {
        // Лимит 500 байт. Пишем сначала msg-1, потом msg-2 — оба больше 250 байт
        let html1 = String(repeating: "a", count: 300)
        let html2 = String(repeating: "b", count: 300)
        await manager.writeBody(messageID: "msg-1", processedHTML: html1)
        // Небольшая пауза чтобы atime различался
        try await Task.sleep(nanoseconds: 10_000_000)
        await manager.writeBody(messageID: "msg-2", processedHTML: html2)
        // msg-1 должна быть вытеснена (старше)
        let r1 = await manager.readBody(messageID: "msg-1")
        XCTAssertNil(r1, "Oldest entry should be evicted")
        let r2 = await manager.readBody(messageID: "msg-2")
        XCTAssertNotNil(r2, "Newest entry should remain")
    }
}
```

- [ ] **Шаг 4.2: Убедиться что тесты падают**

```bash
swift test --package-path Packages/UI --filter CacheManagerTests 2>&1 | tail -5
```

- [ ] **Шаг 4.3: Создать CacheManager.swift**

```swift
// Packages/UI/Sources/UI/Cache/CacheManager.swift
import Foundation

public actor CacheManager {
    private let bodyCache: MessageBodyCache
    private let attachmentCache: AttachmentCacheStore
    private var limitBytes: Int

    public static let defaultLimitBytes = 500 * 1024 * 1024  // 500 МБ

    public init(
        bodyCache: MessageBodyCache,
        attachmentCache: AttachmentCacheStore,
        limitBytes: Int? = nil
    ) {
        self.bodyCache = bodyCache
        self.attachmentCache = attachmentCache
        self.limitBytes = limitBytes ?? UserDefaults.standard.integer(forKey: "cacheLimitBytes")
            .nonZero ?? CacheManager.defaultLimitBytes
    }

    // MARK: - Public API

    public func readBody(messageID: String) async -> String? {
        await bodyCache.read(messageID: messageID)
    }

    public func writeBody(messageID: String, processedHTML: String) async {
        await bodyCache.write(messageID: messageID, processedHTML: processedHTML)
        await evictIfNeeded()
    }

    public func invalidateBody(messageID: String) async {
        await bodyCache.invalidate(messageID: messageID)
    }

    public func readAttachment(messageID: String, contentID: String) async -> (Data, String)? {
        await attachmentCache.read(messageID: messageID, contentID: contentID)
    }

    public func writeAttachment(messageID: String, contentID: String, data: Data, mimeType: String) async {
        await attachmentCache.write(messageID: messageID, contentID: contentID, data: data, mimeType: mimeType)
        await evictIfNeeded()
    }

    public func totalSize() async -> Int {
        await bodyCache.totalSize() + attachmentCache.totalSize()
    }

    public func clearAll() async {
        _ = await bodyCache.clearAll()
        _ = await attachmentCache.clearAll()
    }

    public func setLimit(bytes: Int) {
        limitBytes = bytes
        UserDefaults.standard.set(bytes, forKey: "cacheLimitBytes")
    }

    public var formattedSize: String {
        get async {
            let bytes = await totalSize()
            let mb = Double(bytes) / 1_048_576
            let limit = Double(limitBytes) / 1_048_576
            return String(format: "%.0f МБ из %.0f МБ", mb, limit)
        }
    }

    // MARK: - LRU eviction

    public func evictIfNeeded() async {
        let total = await totalSize()
        guard total > limitBytes else { return }

        // Собираем все записи по messageIDHash с датой доступа тела письма
        let bodyFiles = await bodyCache.allFiles()
        // Сортируем от старейшего к новейшему
        let sorted = bodyFiles.sorted { $0.date < $1.date }

        var current = total
        for entry in sorted {
            guard current > limitBytes else { break }
            let sizeOfEntry = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: entry.url)
            await attachmentCache.deleteByMessageIDHash(entry.messageIDHash)
            current -= sizeOfEntry
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
```

- [ ] **Шаг 4.4: Запустить тесты**

```bash
swift test --package-path Packages/UI --filter CacheManagerTests 2>&1 | tail -20
```

- [ ] **Шаг 4.5: Коммит**

```bash
git add Packages/UI/Sources/UI/Cache/CacheManager.swift \
        Packages/UI/Tests/UITests/CacheTests.swift
git commit -m "feat(ui): CacheManager — LRU eviction 500МБ, фасад для Settings"
```

---

## Task 5: MailCIDSchemeHandler

**Files:**
- Create: `Packages/UI/Sources/UI/Reader/MailCIDSchemeHandler.swift`

> Этот компонент требует `WKWebView` — полноценный unit-тест сложен. Проверяем через интеграцию в Task 6.

- [ ] **Шаг 5.1: Создать MailCIDSchemeHandler.swift**

```swift
// Packages/UI/Sources/UI/Reader/MailCIDSchemeHandler.swift
import WebKit
import Foundation

/// WKURLSchemeHandler для схемы cid:.
/// Является NSObject (WKURLSchemeHandler — @objc протокол, актор не подходит).
/// Делегирует фактический поиск данных в CacheManager через async callback.
public final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    public typealias DataProvider = (String, String) async -> (Data, String)?
    // (messageID, contentID) -> (data, mimeType)?

    private var currentMessageID: String = ""
    private let dataProvider: DataProvider

    public init(dataProvider: @escaping DataProvider) {
        self.dataProvider = dataProvider
    }

    public func setCurrentMessage(_ messageID: String) {
        currentMessageID = messageID
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // cid:image001 — host содержит contentID
        let contentID = url.host ?? url.absoluteString.dropFirst("cid:".count).description
        let msgID = currentMessageID

        Task {
            if let (data, mimeType) = await dataProvider(msgID, contentID) {
                let response = URLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Отмена: Task уже запущен, но результат будет проигнорирован
    }
}
```

- [ ] **Шаг 5.2: Убедиться что пакет компилируется**

```bash
swift build --package-path Packages/UI 2>&1 | tail -10
```
Ожидаемый результат: `Build complete!`

- [ ] **Шаг 5.3: Коммит**

```bash
git add Packages/UI/Sources/UI/Reader/MailCIDSchemeHandler.swift
git commit -m "feat(ui): MailCIDSchemeHandler — WKURLSchemeHandler для cid:-изображений"
```

---

## Task 6: MessageWebView + MessageWebViewController

**Files:**
- Create: `Packages/UI/Sources/UI/Reader/MessageWebView.swift`

> UI-компонент, тестируется вручную. Unit-тест навигационной политики — отдельный файл при необходимости.

- [ ] **Шаг 6.1: Создать MessageWebView.swift**

```swift
// Packages/UI/Sources/UI/Reader/MessageWebView.swift
import SwiftUI
import WebKit
import AppKit

/// SwiftUI-обёртка над WKWebView для отображения HTML-письма.
public struct MessageWebView: NSViewRepresentable {
    public let processedEmail: ProcessedEmail
    public let messageID: String
    public let cacheManager: CacheManager

    public init(processedEmail: ProcessedEmail, messageID: String, cacheManager: CacheManager) {
        self.processedEmail = processedEmail
        self.messageID = messageID
        self.cacheManager = cacheManager
    }

    public func makeNSView(context: Context) -> WKWebView {
        let handler = MailCIDSchemeHandler { msgID, contentID in
            await cacheManager.readAttachment(messageID: msgID, contentID: contentID)
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(handler, forURLScheme: "cid")
        config.preferences.setValue(false, forKey: "allowFileAccessFromFileURLs")

        let controller = MessageWebViewController(
            configuration: config,
            cidHandler: handler,
            processedEmail: processedEmail,
            messageID: messageID
        )
        context.coordinator.viewController = controller
        return controller.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let vc = context.coordinator.viewController else { return }
        if vc.currentMessageID != messageID {
            vc.load(processedEmail: processedEmail, messageID: messageID)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var viewController: MessageWebViewController?
    }
}

/// NSViewController — WKNavigationDelegate + тёмная тема.
public final class MessageWebViewController: NSObject, WKNavigationDelegate, @unchecked Sendable {
    public let webView: WKWebView
    private let cidHandler: MailCIDSchemeHandler
    public private(set) var currentMessageID: String = ""

    public init(
        configuration: WKWebViewConfiguration,
        cidHandler: MailCIDSchemeHandler,
        processedEmail: ProcessedEmail,
        messageID: String
    ) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.cidHandler = cidHandler
        super.init()
        self.webView.navigationDelegate = self
        load(processedEmail: processedEmail, messageID: messageID)

        // Следим за сменой темы
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: NSNotification.Name("NSSystemColorsDidChangeNotification"),
            object: nil
        )
    }

    public func load(processedEmail: ProcessedEmail, messageID: String) {
        currentMessageID = messageID
        cidHandler.setCurrentMessage(messageID)
        // Очищаем перед загрузкой нового письма
        webView.loadHTMLString("", baseURL: nil)
        injectDarkModeCSS(hasDarkModeSupport: processedEmail.hasDarkModeSupport)
        webView.loadHTMLString(processedEmail.html, baseURL: URL(string: "about:blank"))
    }

    // MARK: - Dark mode

    @objc private func appearanceDidChange() {
        injectDarkModeCSS(hasDarkModeSupport: nil)
    }

    private func injectDarkModeCSS(hasDarkModeSupport: Bool?) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard isDark else {
            webView.evaluateJavaScript("document.getElementById('mailai-dark-mode-css')?.remove()")
            return
        }
        guard !(hasDarkModeSupport ?? false) else { return }

        let css = """
        html { filter: invert(1) hue-rotate(180deg); }
        img, video, picture { filter: invert(1) hue-rotate(180deg); }
        """
        let js = """
        (function(){
          var el = document.getElementById('mailai-dark-mode-css');
          if (!el) { el = document.createElement('style'); el.id = 'mailai-dark-mode-css'; document.head.appendChild(el); }
          el.textContent = '\(css.replacingOccurrences(of: "\n", with: " "))';
        })();
        """
        webView.evaluateJavaScript(js)
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "about":
            decisionHandler(.allow)
        case "https":
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow) // subresource
            }
        case "http", "javascript", "file":
            decisionHandler(.cancel)
        case "data":
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow) // data:image/* как subresource
            }
        default:
            decisionHandler(.cancel)
        }
    }
}
```

- [ ] **Шаг 6.2: Убедиться что пакет компилируется**

```bash
swift build --package-path Packages/UI 2>&1 | tail -10
```

- [ ] **Шаг 6.3: Коммит**

```bash
git add Packages/UI/Sources/UI/Reader/MessageWebView.swift
git commit -m "feat(ui): MessageWebView + MessageWebViewController — WKWebView, dark mode, navigation policy"
```

---

## Task 7: Обновить ReaderBodyView

**Files:**
- Modify: `Packages/UI/Sources/UI/ReaderBodyView.swift`
- Modify: `Packages/UI/Tests/UITests/PlaceholderTests.swift`

- [ ] **Шаг 7.1: Обновить ReaderBodyView.swift**

Заменить содержимое файла:

```swift
// Packages/UI/Sources/UI/ReaderBodyView.swift
import SwiftUI
import Core

/// Рендер тела письма.
/// Plain text — нативный SwiftUI Text.
/// HTML — WKWebView через MessageWebView с кешем, dark mode и quote-collapsing.
public struct ReaderBodyView: View {
    public let messageBody: MessageBody
    public let messageID: String
    public let attachments: [Attachment]
    public let cacheManager: CacheManager
    public var onSaveAttachment: (Attachment) -> Void
    @Binding public var isFocused: Bool
    @State private var processedEmail: ProcessedEmail?
    @State private var showImages: Bool = false

    public init(
        body: MessageBody,
        messageID: String,
        attachments: [Attachment] = [],
        cacheManager: CacheManager,
        onSaveAttachment: @escaping (Attachment) -> Void = { _ in },
        isFocused: Binding<Bool> = .constant(false)
    ) {
        self.messageBody = body
        self.messageID = messageID
        self.attachments = attachments
        self.cacheManager = cacheManager
        self.onSaveAttachment = onSaveAttachment
        self._isFocused = isFocused
    }

    public var body: some View {
        KeyboardScrollableReader(isFocused: $isFocused) {
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !attachments.isEmpty {
                    Divider().padding(.top, 8)
                    AttachmentListView(
                        attachments: attachments,
                        onSaveAs: { onSaveAttachment($0) }
                    )
                }
            }
            .padding(16)
        }
        .task(id: messageID) { await loadHTML() }
    }

    @ViewBuilder private var content: some View {
        switch messageBody.content {
        case .plain(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        case .html:
            if let email = processedEmail {
                VStack(alignment: .leading, spacing: 4) {
                    if email.hasExternalImages && !showImages {
                        Button("Показать изображения") {
                            showImages = true
                            Task { await loadHTML() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    MessageWebView(
                        processedEmail: email,
                        messageID: messageID,
                        cacheManager: cacheManager
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        }
    }

    private func loadHTML() async {
        // rawHTML всегда доступен из messageBody — используем его и для кеша, и для «Показать изображения»
        guard case .html(let rawHTML) = messageBody.content else { return }
        let blockImages = !showImages && UserDefaults.standard.bool(forKey: "blockExternalImages")

        // Кеш-хит только если изображения не нужно принудительно показывать
        if !showImages, let cached = await cacheManager.readBody(messageID: messageID) {
            processedEmail = ProcessedEmail(
                html: cached,
                hasDarkModeSupport: cached.contains("prefers-color-scheme"),
                hasExternalImages: cached.range(of: #"src\s*=\s*["']https?://"#, options: .regularExpression) != nil
            )
            return
        }

        // Обрабатываем из сырого HTML (кеш-мисс или «Показать изображения»)
        let email = await HTMLPreprocessor().process(rawHTML, blockExternalImages: blockImages)
        if !showImages {
            // Кешируем только версию с заблокированными изображениями (дефолт)
            await cacheManager.writeBody(messageID: messageID, processedHTML: email.html)
        }
        processedEmail = email
    }
}
```

- [ ] **Шаг 7.2: Удалить HTMLSanitizerTests из PlaceholderTests.swift**

`HTMLSanitizer` больше не существует. Удалить класс `HTMLSanitizerTests` из файла, оставив `UIFormatterTests`:

```swift
// Packages/UI/Tests/UITests/PlaceholderTests.swift
#if canImport(XCTest)
import XCTest
@testable import UI

final class UIFormatterTests: XCTestCase {
    func testSameDayReturnsHHmm() {
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let sameDay = now.addingTimeInterval(-600)
        let s = MessageDateFormatter.short(sameDay, now: now, locale: Locale(identifier: "ru_RU"))
        XCTAssertTrue(s.contains(":"))
    }

    func testYesterdayReturnsLocalized() {
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        let yesterday = now.addingTimeInterval(-3600 * 24)
        let s = MessageDateFormatter.short(yesterday, now: now, locale: Locale(identifier: "ru_RU"))
        XCTAssertEqual(s, "Вчера")
    }
}
#endif
```

- [ ] **Шаг 7.3: Запустить все тесты пакета**

```bash
swift test --package-path Packages/UI 2>&1 | tail -20
```
Ожидаемый результат: все тесты зелёные, `HTMLSanitizerTests` отсутствует.

- [ ] **Шаг 7.4: Убедиться что проект компилируется**

```bash
swift build --package-path Packages/UI 2>&1 | tail -5
```

- [ ] **Шаг 7.5: Коммит**

```bash
git add Packages/UI/Sources/UI/ReaderBodyView.swift \
        Packages/UI/Tests/UITests/PlaceholderTests.swift
git commit -m "feat(ui): ReaderBodyView — подключить MessageWebView, убрать HTMLSanitizer"
```

---

## Task 8: Settings UI

**Files:**
- Modify: найти `SettingsView` в AppShell и добавить секции. Файл: `Packages/AppShell/Sources/AppShell/` — найти grep'ом.

- [ ] **Шаг 8.1: Найти файл настроек**

```bash
grep -rl "SettingsView\|PreferencesView\|Settings" \
  Packages/AppShell/Sources/ --include="*.swift" | head -5
```

- [ ] **Шаг 8.2: Добавить ViewModel для кеша**

В файл `Packages/UI/Sources/UI/Cache/CacheManager.swift` добавить `@MainActor`-класс для SwiftUI:

```swift
@MainActor
public final class CacheSettingsViewModel: ObservableObject {
    @Published public var formattedSize: String = "—"
    @Published public var limitMB: Int

    private let manager: CacheManager

    public init(manager: CacheManager) {
        self.manager = manager
        self.limitMB = (UserDefaults.standard.integer(forKey: "cacheLimitBytes").nonZero
            ?? CacheManager.defaultLimitBytes) / (1024 * 1024)
    }

    public func refresh() async {
        formattedSize = await manager.formattedSize
    }

    public func clearCache() async {
        await manager.clearAll()
        await refresh()
    }

    public func updateLimit() {
        let bytes = limitMB * 1024 * 1024
        Task { await manager.setLimit(bytes: bytes) }
    }
}
```

- [ ] **Шаг 8.3: Добавить секции в SettingsView**

Найти файл настроек (из шага 8.1). Добавить:

```swift
// Секция кеша — добавить в тело Form/List настроек
Section("Кеш") {
    HStack {
        VStack(alignment: .leading) {
            Text("Письма и вложения")
            Text(cacheVM.formattedSize)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        Spacer()
        Button("Очистить кеш", role: .destructive) {
            Task { await cacheVM.clearCache() }
        }
    }
    LabeledContent("Максимальный размер кеша") {
        Stepper(
            value: $cacheVM.limitMB,
            in: 50...10240,
            step: 50,
            onEditingChanged: { _ in cacheVM.updateLimit() }
        ) {
            Text("\(cacheVM.limitMB) МБ")
        }
    }
}

Section("Приватность") {
    Toggle("Блокировать внешние изображения",
           isOn: Binding(
               get: { UserDefaults.standard.bool(forKey: "blockExternalImages") },
               set: { UserDefaults.standard.set($0, forKey: "blockExternalImages") }
           ))
    Text("Скрывает трекер-пиксели и внешние картинки. Кнопка «Показать изображения» позволяет разрешить для отдельного письма.")
        .foregroundStyle(.secondary)
        .font(.caption)
}
```

Добавить `.task { await cacheVM.refresh() }` к корневому `View`.

- [ ] **Шаг 8.4: Убедиться что пакеты компилируются**

```bash
swift build --package-path Packages/UI 2>&1 | tail -5
swift build --package-path Packages/AppShell 2>&1 | tail -5
```

- [ ] **Шаг 8.5: Коммит**

```bash
git add Packages/UI/Sources/UI/Cache/CacheManager.swift
git add Packages/AppShell/  # только изменённые файлы
git commit -m "feat(settings): секции кеша и блокировки внешних изображений"
```

---

## Task 9: Обновить CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Шаг 9.1: Обновить правило о хранении данных**

Найти раздел `## Правила` в `CLAUDE.md`. Заменить:

```
- **Память прежде всего**: тела писем держим в памяти только на время активной работы с ними; освобождаем сразу после использования. Стримим крупные тела, не загружаем целиком без нужды.
- **Никаких текстов писем на диске**: ни в кеше, ни в БД, ни в логах. В SQLite/GRDB — только метаданные (message-id, заголовки, флаги, размеры, хеши).
```

На:

```
- **Кеш писем**: обработанные HTML-тела и бинарные вложения кешируются в `~/Library/Caches/MailAi/` (bodies/ и attachments/). Лимит по умолчанию 500 МБ, LRU-вытеснение по дате доступа. Пользователь может очистить кеш в Settings. В SQLite/GRDB — только метаданные (message-id, заголовки, флаги, размеры, хеши).
- **Логи и БД**: тела писем и их фрагменты — только в `~/Library/Caches/MailAi/`, не в SQLite, не в логах, не в git.
```

Найти и обновить секцию `## Запрещено`:

Заменить:
```
- Сохранять тела писем и их фрагменты в любом персистентном хранилище.
```
На:
```
- Сохранять тела писем вне `~/Library/Caches/MailAi/` (не в SQLite, не во временных файлах за пределами Caches, не в логах).
```

- [ ] **Шаг 9.2: Коммит**

```bash
git add CLAUDE.md
git commit -m "docs: обновить политику хранения — кеш писем в ~/Library/Caches/MailAi/"
```

---

## Финальная проверка

- [ ] Все тесты UI-пакета зелёные:
  ```bash
  swift test --package-path Packages/UI 2>&1 | tail -10
  ```
- [ ] Все пакеты компилируются:
  ```bash
  swift build --package-path Packages/UI && swift build --package-path Packages/AppShell
  ```
- [ ] Вручную открыть письмо с HTML — проверить рендер, схлопывание цитат
- [ ] Проверить тёмную тему: System Preferences → Appearance → Dark
- [ ] Проверить кнопку «Показать изображения» на письме с внешними картинками
- [ ] Проверить кнопку «Очистить кеш» в Settings — размер обнуляется
