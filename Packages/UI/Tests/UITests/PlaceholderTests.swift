#if canImport(XCTest)
import XCTest
@testable import UI

final class HTMLSanitizerTests: XCTestCase {
    func testStripsTagsAndScripts() {
        let html = "<p>Hello <b>world</b></p><script>alert('x')</script>"
        let text = HTMLSanitizer.plainText(from: html)
        XCTAssertFalse(text.contains("<"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
    }

    func testDecodesEntities() {
        let html = "Tom &amp; Jerry &lt;3 &quot;code&quot;"
        XCTAssertEqual(HTMLSanitizer.plainText(from: html), "Tom & Jerry <3 \"code\"")
    }

    func testNoExternalResourcesLeak() {
        // Санитайзер не должен рендерить ссылки и не трогает URL — просто
        // выкидывает теги. Тест фиксирует инвариант: в выходе нет «<img» и «<a».
        let html = "<img src='https://evil/x.png'><a href='https://evil/'>link</a>text"
        let text = HTMLSanitizer.plainText(from: html)
        XCTAssertFalse(text.contains("<"))
        XCTAssertTrue(text.contains("link"))
        XCTAssertTrue(text.contains("text"))
    }
}

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
