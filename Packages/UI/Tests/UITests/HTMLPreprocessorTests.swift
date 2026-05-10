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

    // MARK: - Sanitization: scripts

    func testRemovesInlineScript() async {
        let html = #"<p>Hello</p><script>alert('xss')</script><p>World</p>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertFalse(result.html.contains("<script"), "inline <script> should be removed")
        XCTAssertFalse(result.html.contains("alert("), "script content should be removed")
        XCTAssertTrue(result.html.contains("World"), "non-script content should remain")
    }

    func testRemovesScriptWithAttributes() async {
        let html = #"<script type="text/javascript" src="evil.js"></script>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertFalse(result.html.contains("<script"))
    }

    // MARK: - Sanitization: tracking pixels

    func testRemovesTrackingPixelWidthOne() async {
        let html = #"<p>Hi</p><img src="https://tracker.com/px" width="1" height="1"><p>Text</p>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertFalse(result.html.contains("tracker.com/px"), "tracking pixel should be removed")
        XCTAssertTrue(result.html.contains("Text"), "other content should remain")
    }

    func testRemovesTrackingPixelWidthZero() async {
        let html = #"<img src="https://tracker.com/px" width="0" height="0">"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertFalse(result.html.contains("tracker.com/px"))
    }

    func testKeepsNormalImages() async {
        let html = #"<img src="https://example.com/banner.jpg" width="600" height="200">"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("banner.jpg"), "normal image should not be removed")
    }

    // MARK: - Sanitization: javascript hrefs

    func testRemovesJavascriptHref() async {
        let html = #"<a href="javascript:alert('xss')">Click</a>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertFalse(result.html.lowercased().contains("javascript:"), "javascript: href should be removed")
        XCTAssertTrue(result.html.contains("Click"), "link text should remain")
    }

    func testJavascriptHrefReplacedWithHash() async {
        let html = #"<a href="javascript:void(0)">Link</a>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("href=\"#\""), "javascript: href should be replaced with #")
    }

    // MARK: - Sanitization: remote stylesheets

    func testRemovesRemoteStylesheet() async {
        let html = #"<link rel="stylesheet" href="https://evil.com/styles.css"><p>Text</p>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertFalse(result.html.contains("evil.com/styles.css"), "remote stylesheet should be removed")
        XCTAssertTrue(result.html.contains("Text"), "content should remain")
    }

    func testKeepsInlineStyle() async {
        let html = #"<p style="color:red">Text</p>"#
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertTrue(result.html.contains("color:red"), "inline style should remain")
    }

    // MARK: - Sanitization: expression() in style

    func testRemovesExpressionFromStyle() async {
        let html = "<style>div { width: expression(alert(1)); }</style><p>Text</p>"
        let result = await HTMLPreprocessor().process(html, blockExternalImages: false)
        XCTAssertFalse(result.html.contains("expression("), "expression() should be removed from style")
        XCTAssertTrue(result.html.contains("Text"))
    }
}
#endif
