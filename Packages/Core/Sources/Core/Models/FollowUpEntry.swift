import Foundation

/// Запись в очереди ожидания ответа на отправленное письмо.
///
/// Хранит только идентификаторы и временны́е метки — без тел писем, адресов.
/// Соответствует таблице `follow_up_queue` (SchemaV7).
public struct FollowUpEntry: Sendable, Identifiable, Equatable {
    /// Идентификатор письма (PK).
    public let messageID: Message.ID
    /// Дата отправки письма.
    public let sentDate: Date
    /// Дата, после которой ожидается напоминание (если нет ответа).
    public let dueDate: Date
    /// Идентификатор треда (для определения наличия ответа).
    public let threadID: MessageThread.ID?
    /// `true` — ситуация разрешена (ответ получен или пользователь закрыл вручную).
    public let isResolved: Bool
    /// Дата разрешения ситуации, если `isResolved == true`.
    public let resolvedAt: Date?
    /// Дата создания записи.
    public let createdAt: Date

    public var id: Message.ID { messageID }

    public init(
        messageID: Message.ID,
        sentDate: Date,
        dueDate: Date,
        threadID: MessageThread.ID? = nil,
        isResolved: Bool = false,
        resolvedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.messageID = messageID
        self.sentDate = sentDate
        self.dueDate = dueDate
        self.threadID = threadID
        self.isResolved = isResolved
        self.resolvedAt = resolvedAt
        self.createdAt = createdAt
    }
}

/// Протокол анализатора исходящих писем на предмет ожидания ответа.
///
/// Весь анализ происходит в памяти; тела писем не сохраняются на диск.
public protocol AIFollowUpAnalyzer: Sendable {
    /// Анализирует исходящее письмо и определяет, ожидает ли оно ответа.
    ///
    /// - Parameters:
    ///   - subject: Тема письма.
    ///   - bodySnippet: Первые 300 символов plain-text тела (только в памяти).
    /// - Returns: `(expectsReply: Bool, daysToFollowUp: Int?)` — если `expectsReply == false`,
    ///   `daysToFollowUp` равен nil.
    func analyze(subject: String, bodySnippet: String) async throws -> FollowUpAnalysis
}

/// Результат анализа письма на ожидание ответа.
public struct FollowUpAnalysis: Sendable, Equatable {
    /// `true` — письмо вероятно ожидает ответа.
    public let expectsReply: Bool
    /// Через сколько дней уместно ожидать ответ. Nil если `expectsReply == false`.
    /// Допустимые значения: 1, 3, 7, 14.
    public let daysToFollowUp: Int?

    public init(expectsReply: Bool, daysToFollowUp: Int?) {
        self.expectsReply = expectsReply
        self.daysToFollowUp = daysToFollowUp
    }
}
