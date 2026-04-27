import SwiftUI
import Core

/// Рендер тела письма. Plain — как есть; HTML — через безопасный санитайзер
/// (без внешних ресурсов, без JS). Полноценный WKWebView с офлайн-политикой —
/// задача более поздней фазы (см. docs/UI.md).
///
/// A6: скролл внутри reader обрабатывается нативным `NSScrollView`
/// через `KeyboardScrollableReader`, что даёт Space (pageDown),
/// Shift+Space (pageUp), стрелки и PageUp/PageDown.
public struct ReaderBodyView: View {
    public let messageBody: MessageBody
    public let attachments: [Attachment]
    @Binding public var isFocused: Bool

    public init(
        body: MessageBody,
        attachments: [Attachment] = [],
        isFocused: Binding<Bool> = .constant(false)
    ) {
        self.messageBody = body
        self.attachments = attachments
        self._isFocused = isFocused
    }

    public var body: some View {
        KeyboardScrollableReader(isFocused: $isFocused) {
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !attachments.isEmpty {
                    Divider()
                        .padding(.top, 8)
                    AttachmentListView(attachments: attachments)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var content: some View {
        switch messageBody.content {
        case .plain(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        case .html(let html):
            Text(HTMLSanitizer.plainText(from: html))
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

/// Минимальный санитайзер HTML: вырезает теги и скрипты, декодирует
/// базовые HTML-сущности. Никогда не исполняет код и не тянет ресурсы.
public enum HTMLSanitizer {
    public static func plainText(from html: String) -> String {
        var text = html
        text = removeBlocks(text, tag: "script")
        text = removeBlocks(text, tag: "style")
        text = stripTags(text)
        text = decodeEntities(text)
        return collapseWhitespace(text)
    }

    private static func removeBlocks(_ input: String, tag: String) -> String {
        var out = input
        while let openRange = out.range(of: "<\(tag)", options: .caseInsensitive),
              let closeRange = out.range(of: "</\(tag)>", options: .caseInsensitive, range: openRange.upperBound..<out.endIndex) {
            out.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return out
    }

    private static func stripTags(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var insideTag = false
        for ch in input {
            if ch == "<" { insideTag = true; continue }
            if ch == ">" { insideTag = false; out.append(" "); continue }
            if !insideTag { out.append(ch) }
        }
        return out
    }

    private static func decodeEntities(_ input: String) -> String {
        var out = input
        let map: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        for (from, to) in map {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    private static func collapseWhitespace(_ input: String) -> String {
        let lines = input.split(whereSeparator: { $0.isNewline }).map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
