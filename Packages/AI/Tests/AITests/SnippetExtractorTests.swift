#if canImport(XCTest)
import XCTest
@testable import AI

final class SnippetExtractorTests: XCTestCase {

    func testExactLength150ForShortBody() {
        let snippet = SnippetExtractor.extract(body: "Коротко.", contentType: "text/plain")
        XCTAssertEqual(snippet.count, 150)
        XCTAssertTrue(snippet.hasPrefix("Коротко."))
    }

    func testExactLength150ForLongBody() {
        let long = String(repeating: "Лорем ипсум долор сит амет ", count: 50)
        let snippet = SnippetExtractor.extract(body: long, contentType: "text/plain")
        XCTAssertEqual(snippet.count, 150)
    }

    func testEmptyBodyReturnsSpaces() {
        let snippet = SnippetExtractor.extract(body: "", contentType: "text/plain")
        XCTAssertEqual(snippet.count, 150)
        XCTAssertEqual(snippet.trimmingCharacters(in: .whitespaces), "")
    }

    func testStripsHTMLTags() {
        let html = "<p>Привет, <b>друзья</b>!</p><br/><p>Как дела?</p>"
        let snippet = SnippetExtractor.extract(body: html, contentType: "text/html")
        XCTAssertFalse(snippet.contains("<"))
        XCTAssertFalse(snippet.contains("<p>"))
        XCTAssertTrue(snippet.contains("Привет"))
        XCTAssertTrue(snippet.contains("Как дела"))
    }

    func testDecodesHTMLEntities() {
        let html = "Tom &amp; Jerry &lt;eot&gt; &nbsp; and &quot;tests&quot;"
        let snippet = SnippetExtractor.extract(body: html, contentType: "text/html")
        XCTAssertTrue(snippet.contains("Tom & Jerry"))
        XCTAssertTrue(snippet.contains("<eot>"))
        XCTAssertTrue(snippet.contains("\"tests\""))
    }

    func testStripsQuotedReply() {
        let body = """
            Новый текст письма.

            > On 1 Apr 2026, at 10:00, someone@example.com wrote:
            > Это цитата
            > которую не должны включать
            """
        let snippet = SnippetExtractor.extract(body: body, contentType: "text/plain")
        XCTAssertFalse(snippet.contains("wrote:"))
        XCTAssertFalse(snippet.contains("цитата"))
        XCTAssertTrue(snippet.contains("Новый текст"))
    }

    func testStripsSignature() {
        let body = "Текст письма.\n-- \nС уважением,\nИван"
        let snippet = SnippetExtractor.extract(body: body, contentType: "text/plain")
        XCTAssertFalse(snippet.contains("С уважением"))
        XCTAssertFalse(snippet.contains("Иван"))
        XCTAssertTrue(snippet.contains("Текст письма"))
    }

    func testNormalizesWhitespaceAndNewlines() {
        let body = "Строка 1.\n\n\n\n   Строка 2.   \t\tСтрока 3."
        let snippet = SnippetExtractor.extract(body: body, contentType: "text/plain")
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertFalse(snippet.contains("\t"))
        // Нет двойных пробелов внутри содержимого (trailing padding не учитываем).
        let trimmed = snippet.trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(trimmed.contains("  "))
    }

    func testHTMLAndQuotedAndSignatureTogether() {
        // RFC 3676: signature delimiter is "-- \n" (два дефиса + пробел + перевод строки).
        let body = "<p>Привет, <b>друг</b>!</p><p>Нужно обсудить проект.</p>\n-- \nПодпись"
        let snippet = SnippetExtractor.extract(body: body, contentType: "text/html")
        XCTAssertTrue(snippet.contains("Привет"))
        XCTAssertTrue(snippet.contains("проект"))
        XCTAssertFalse(snippet.contains("Подпись"))
        XCTAssertFalse(snippet.contains("<"))
    }

    func testCustomLength() {
        let snippet = SnippetExtractor.extract(body: "Test", contentType: "text/plain", length: 50)
        XCTAssertEqual(snippet.count, 50)
    }
}
#endif
