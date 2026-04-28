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

    func testCollapsesOutlookQuoteWithSuffix() async {
        let html = #"<p>Reply</p><div id="divRplyFwdMsg123"><p>Original</p></div>"#
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

    func testInjectsMetaInHtmlWithoutHead() async {
        let html = "<html><body><p>Hello</p></body></html>"
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("Content-Security-Policy"), "CSP should be injected even when <head> is missing")
        XCTAssertTrue(result.html.contains("viewport"), "Viewport should be injected even when <head> is missing")
    }

    func testEnsuresHtmlHeadBodyStructure() async {
        let result = await HTMLPreprocessor().process("<p>Hello</p>", blockExternalImages: false)
        XCTAssertTrue(result.html.hasPrefix("<!DOCTYPE html>") || result.html.contains("<html"))
        XCTAssertTrue(result.html.contains("<head>") || result.html.contains("<head "))
        XCTAssertTrue(result.html.contains("<body>") || result.html.contains("<body "))
    }
}
#endif
