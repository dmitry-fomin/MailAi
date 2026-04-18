import Foundation

/// Выделяет ровно 150 символов plain-text из письма для отправки в AI-классификатор.
/// Строгий контракт: размер результата всегда = `length` (padding пробелами, если
/// исходник короче). HTML удаляется, quoted-reply обрезается, подпись после
/// `-- ` вычёркивается.
public enum SnippetExtractor {
    public static func extract(
        body: String,
        contentType: String,
        length: Int = 150
    ) -> String {
        let stripped = stripHTMLIfNeeded(body, contentType: contentType)
        let noQuoted = stripQuotedReply(stripped)
        let noSig = stripSignature(noQuoted)
        let normalized = noSig
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return String(repeating: " ", count: length) }
        if normalized.count >= length {
            return String(normalized.prefix(length))
        }
        // padding(toLength:) считает в UTF-16, а наш инвариант — grapheme count.
        // Делаем padding вручную до ровно `length` Character'ов.
        let deficit = length - normalized.count
        return normalized + String(repeating: " ", count: deficit)
    }

    private static func stripHTMLIfNeeded(_ body: String, contentType: String) -> String {
        guard contentType.lowercased().contains("html") else { return body }
        return body
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private static func stripQuotedReply(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(while: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(">") { return false }
                if trimmed.hasPrefix("On ") && trimmed.contains(" wrote:") { return false }
                return true
            })
            .joined(separator: "\n")
    }

    private static func stripSignature(_ body: String) -> String {
        if let range = body.range(of: "\n-- \n") {
            return String(body[..<range.lowerBound])
        }
        if body.hasSuffix("\n-- ") {
            return String(body.dropLast(4))
        }
        return body
    }
}
