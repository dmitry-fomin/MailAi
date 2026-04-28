import Foundation
import Core

/// Разобранный поисковый запрос. Операторы из `docs/Search.md`:
///   `from:alice@example.com` — фильтр по адресу/имени отправителя (FTS match)
///   `has:attachment`         — флаг `.hasAttachment`
///   `is:unread`              — флаг `!seen`
///   `is:flagged`             — флаг `.flagged`
///   `before:2026-04-01`      — дата < указанной (ISO 8601 date)
///   `after:2026-01-01`       — дата >= указанной
/// Всё остальное — свободный текст, попадает в `MATCH` по всем FTS-полям.
public struct SearchQuery: Sendable, Equatable {
    public var freeText: String
    public var from: String?
    public var hasAttachment: Bool?
    public var isUnread: Bool?
    public var isFlagged: Bool?
    public var before: Date?
    public var after: Date?

    public init(
        freeText: String = "",
        from: String? = nil,
        hasAttachment: Bool? = nil,
        isUnread: Bool? = nil,
        isFlagged: Bool? = nil,
        before: Date? = nil,
        after: Date? = nil
    ) {
        self.freeText = freeText
        self.from = from
        self.hasAttachment = hasAttachment
        self.isUnread = isUnread
        self.isFlagged = isFlagged
        self.before = before
        self.after = after
    }

    public var isEmpty: Bool {
        freeText.trimmingCharacters(in: .whitespaces).isEmpty
            && from == nil && hasAttachment == nil
            && isUnread == nil && isFlagged == nil
            && before == nil && after == nil
    }
}

public enum SearchQueryParser {
    // ISO8601DateFormatter потокобезопасен (в отличие от DateFormatter),
    // поэтому безопасен как static-синглтон при strict concurrency.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        var freeWords: [String] = []

        // Простая токенизация по whitespace. Кавычки не поддерживаем пока.
        for token in input.split(whereSeparator: { $0.isWhitespace }) {
            let str = String(token)
            if let colon = str.firstIndex(of: ":"), colon != str.startIndex, colon != str.index(before: str.endIndex) {
                let key = str[..<colon].lowercased()
                let value = String(str[str.index(after: colon)...])
                switch key {
                case "from":
                    query.from = value
                case "has":
                    if value.lowercased() == "attachment" { query.hasAttachment = true }
                case "is":
                    switch value.lowercased() {
                    case "unread":  query.isUnread = true
                    case "read":    query.isUnread = false
                    case "flagged": query.isFlagged = true
                    default: freeWords.append(str)
                    }
                case "before":
                    if let date = dateFormatter.date(from: value) { query.before = date }
                case "after":
                    if let date = dateFormatter.date(from: value) { query.after = date }
                default:
                    freeWords.append(str)
                }
            } else {
                freeWords.append(str)
            }
        }
        query.freeText = freeWords.joined(separator: " ")
        return query
    }
}
