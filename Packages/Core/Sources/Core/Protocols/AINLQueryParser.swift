import Foundation

/// Результат разбора natural-language поискового запроса.
///
/// Поля заполняются только если они явно или неявно присутствуют в запросе.
/// Все nil — запрос не содержит соответствующего условия.
public struct ParsedSearchQuery: Sendable, Equatable {
    /// Адрес или имя отправителя (FROM).
    public var from: String?
    /// Адрес или имя получателя (TO).
    public var to: String?
    /// Ключевые слова для поиска в теме письма (SUBJECT).
    public var subject: String?
    /// Ключевые слова для поиска в теле письма (BODY / TEXT).
    public var body: String?
    /// Начало периода (SINCE, включительно).
    public var dateSince: Date?
    /// Конец периода (BEFORE, не включая).
    public var dateBefore: Date?
    /// Наличие вложений.
    public var hasAttachment: Bool?
    /// Флаг непрочитанного письма.
    public var isUnread: Bool?

    public init(
        from: String? = nil,
        to: String? = nil,
        subject: String? = nil,
        body: String? = nil,
        dateSince: Date? = nil,
        dateBefore: Date? = nil,
        hasAttachment: Bool? = nil,
        isUnread: Bool? = nil
    ) {
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.dateSince = dateSince
        self.dateBefore = dateBefore
        self.hasAttachment = hasAttachment
        self.isUnread = isUnread
    }

    /// `true` — все поля nil (AI ничего не распознал).
    public var isEmpty: Bool {
        from == nil && to == nil && subject == nil && body == nil
            && dateSince == nil && dateBefore == nil
            && hasAttachment == nil && isUnread == nil
    }

    /// Конвертирует в строку запроса для `SearchQueryParser` / `SearchService`.
    ///
    /// Формат совместим с операторами из `docs/Search.md`:
    /// `from:`, `is:unread`, `has:attachment`, `after:`, `before:`.
    /// Свободный текст добавляется без операторов.
    public func toQueryString() -> String {
        var parts: [String] = []

        if let from { parts.append("from:\(from)") }
        if let to   { parts.append("to:\(to)") }
        if let subject { parts.append(subject) }
        if let body    { parts.append(body) }
        if hasAttachment == true  { parts.append("has:attachment") }
        if isUnread == true       { parts.append("is:unread") }
        if isUnread == false      { parts.append("is:read") }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        iso.timeZone = TimeZone(identifier: "UTC")
        if let since  = dateSince  { parts.append("after:\(iso.string(from: since))") }
        if let before = dateBefore { parts.append("before:\(iso.string(from: before))") }

        return parts.joined(separator: " ")
    }
}

/// Протокол AI-транслятора natural-language поисковых запросов.
///
/// Принимает произвольный текст на естественном языке и возвращает
/// структурированные параметры поиска `ParsedSearchQuery`.
///
/// Весь текст остаётся в запросе к AI — тела писем НИКОГДА не передаются.
public protocol AINLQueryParser: Sendable {
    /// Парсит NL-запрос и возвращает структурированные параметры.
    /// Бросает ошибку только при сетевых/IO-проблемах.
    /// Если AI не смог распознать параметры — возвращает `ParsedSearchQuery()` (isEmpty == true).
    func parse(query: String) async throws -> ParsedSearchQuery
}
