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
