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
        let pattern = #"<img[^>]+src\s*=\s*["']https?://"#
        return html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Structure

    private func ensureStructure(_ html: String) -> String {
        let lower = html.lowercased()
        guard lower.contains("<html") else {
            return """
            <!DOCTYPE html>
            <html><head></head><body>
            \(html)
            </body></html>
            """
        }
        // Если <html> есть, но <head> нет — вставляем <head></head>
        if !lower.contains("<head") {
            if let range = html.range(of: #"<html[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                let afterHtml = html[range.upperBound...]
                return String(html[..<range.upperBound]) + "<head></head>" + String(afterHtml)
            }
        }
        return html
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
        * { max-width: 100%; box-sizing: border-box; }
        body { word-wrap: break-word; overflow-wrap: break-word; margin: 0; padding: 0; }
        img { height: auto; }
        details.mail-quote { margin: 8px 0; border-left: 3px solid #ccc; padding-left: 8px; }
        details.mail-quote summary { cursor: pointer; color: #888; font-size: 0.9em; padding: 4px 0; user-select: none; }
        </style>
        """
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
        result = wrapPattern(result, open: #"<div[^>]+class="[^"]*gmail_quote[^"]*""#, closeTag: "div")
        result = wrapPattern(result, open: #"<blockquote[^>]+type="cite""#, closeTag: "blockquote")
        result = wrapPattern(result, open: #"<div[^>]+class="[^"]*AppleOriginalContents[^"]*""#, closeTag: "div")
        result = wrapPattern(result, open: #"<div[^>]+id="divRplyFwdMsg[^"]*""#, closeTag: "div")
        return result
    }

    private func wrapPattern(_ html: String, open openPattern: String, closeTag: String) -> String {
        guard let openRange = html.range(of: openPattern, options: [.regularExpression, .caseInsensitive]) else {
            return html
        }
        let afterOpen = html[openRange.upperBound...]
        let closeStr = "</\(closeTag)>"
        guard let closeRange = afterOpen.range(of: closeStr, options: .caseInsensitive) else {
            return html
        }
        let innerEnd = afterOpen.startIndex..<closeRange.lowerBound
        let inner = String(afterOpen[innerEnd])

        var result = html
        let fullRange = openRange.lowerBound..<afterOpen.index(closeRange.lowerBound, offsetBy: closeStr.count)
        let replacement = "<details class=\"mail-quote\"><summary>Предыдущие сообщения</summary><\(closeTag)>\(inner)</\(closeTag)></details>"
        result.replaceSubrange(fullRange, with: replacement)
        return result
    }
}
