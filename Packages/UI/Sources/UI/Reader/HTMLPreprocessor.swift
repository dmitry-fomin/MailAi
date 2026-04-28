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
        var html = sanitize(rawHTML)
        html = ensureStructure(html)
        html = injectHead(html, blockExternalImages: blockExternalImages)
        html = collapseQuotes(html)
        return ProcessedEmail(html: html, hasDarkModeSupport: hasDarkMode, hasExternalImages: hasExternal)
    }

    // MARK: - Sanitization

    /// Удаляет из HTML потенциально опасные и нежелательные фрагменты:
    /// - `<script>...</script>` — inline-скрипты
    /// - `<img>` с размером 0×0 или 1×1 — tracking-пиксели
    /// - `href="javascript:..."` — javascript-ссылки
    /// - `<link rel="stylesheet" href="https?://...">` — внешние CSS-таблицы
    /// - `expression(...)` в `<style>` — устаревший IE-механизм выполнения кода
    ///
    /// Метод работает на уровне строк с регулярными выражениями — без полного
    /// DOM-парсинга — и является быстрым первичным фильтром. CSP-заголовок,
    /// инжектируемый в `injectHead`, служит второй линией защиты.
    private func sanitize(_ html: String) -> String {
        var result = html

        // 1. Удаляем inline <script>...</script>
        result = removeTag(result, tagPattern: #"<script\b[^>]*>[\s\S]*?</script\s*>"#)

        // 2. Удаляем tracking-пиксели: <img> с width=0/1 или height=0/1
        result = removeTrackingPixels(result)

        // 3. Удаляем href="javascript:..."
        result = removeJavaScriptHrefs(result)

        // 4. Удаляем внешние CSS: <link rel="stylesheet" href="https?://...">
        result = removeRemoteStylesheets(result)

        // 5. Удаляем expression(...) из <style>
        result = sanitizeStyleTags(result)

        return result
    }

    /// Удаляет все вхождения тега, заданного как regex-паттерн.
    private func removeTag(_ html: String, tagPattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    /// Удаляет `<img>` теги, которые являются tracking-пикселями:
    /// width="0", width="1", height="0", height="1" (в любом порядке, включая стиль width:0).
    private func removeTrackingPixels(_ html: String) -> String {
        // Паттерн: <img [атрибуты]> где среди атрибутов есть width=0/1 ИЛИ height=0/1
        // Используем два прохода: сначала width="0"/width="1", потом height аналогично
        let patterns = [
            // width="0" или width="1" или width='0' или width='1'
            #"<img\b(?=[^>]*\bwidth\s*=\s*["']?[01]["']?)[^>]*/?\s*>"#,
            // height="0" или height="1"
            #"<img\b(?=[^>]*\bheight\s*=\s*["']?[01]["']?)[^>]*/?\s*>"#,
            // style с width:0 или width:1px или height:0
            #"<img\b(?=[^>]*\bstyle\s*=\s*["'][^"']*(?:width\s*:\s*[01]|height\s*:\s*[01]))[^>]*/?\s*>"#,
        ]
        var result = html
        for pattern in patterns {
            result = removeTag(result, tagPattern: pattern)
        }
        return result
    }

    /// Заменяет `href="javascript:..."` на `href="#"`.
    private func removeJavaScriptHrefs(_ html: String) -> String {
        let pattern = #"href\s*=\s*["']\s*javascript\s*:[^"']*["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "href=\"#\"")
    }

    /// Удаляет `<link rel="stylesheet" href="https?://...">`.
    private func removeRemoteStylesheets(_ html: String) -> String {
        // Матчим <link ...> с rel=stylesheet И внешним href
        let pattern = #"<link\b(?=[^>]*\brel\s*=\s*["']stylesheet["'])(?=[^>]*\bhref\s*=\s*["']https?://)[^>]*/?\s*>"#
        return removeTag(html, tagPattern: pattern)
    }

    /// Удаляет `expression(...)` из содержимого тегов `<style>`.
    private func sanitizeStyleTags(_ html: String) -> String {
        let stylePattern = #"(<style\b[^>]*>)([\s\S]*?)(</style\s*>)"#
        guard let regex = try? NSRegularExpression(pattern: stylePattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return html
        }
        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)
        var result = html

        // Итерируем блоки <style> в обратном порядке, чтобы не сбивать индексы
        let matches = regex.matches(in: html, range: range).reversed()
        for match in matches {
            guard match.numberOfRanges == 4,
                  let openRange = Range(match.range(at: 1), in: result),
                  let contentRange = Range(match.range(at: 2), in: result),
                  let closeRange = Range(match.range(at: 3), in: result) else { continue }

            let content = String(result[contentRange])
            // Удаляем expression(...) — IE CSS-инъекция
            let sanitizedContent = removeExpression(content)
            if sanitizedContent != content {
                result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound,
                                       with: String(result[openRange]) + sanitizedContent + String(result[closeRange]))
            }
        }
        return result
    }

    private func removeExpression(_ css: String) -> String {
        let pattern = #"expression\s*\([^)]*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return css
        }
        let range = NSRange(css.startIndex..., in: css)
        return regex.stringByReplacingMatches(in: css, range: range, withTemplate: "")
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
