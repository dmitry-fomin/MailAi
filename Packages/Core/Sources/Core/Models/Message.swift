import Foundation

/// Контакт — адрес + (опционально) отображаемое имя. Используется и для from,
/// и для to/cc/bcc.
public struct MailAddress: Sendable, Hashable, Codable {
    public let address: String
    public let name: String?

    public init(address: String, name: String? = nil) {
        self.address = address
        self.name = name
    }
}

/// Флаги письма (IMAP flags + наши локальные).
public struct MessageFlags: Sendable, Hashable, Codable, OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let seen       = MessageFlags(rawValue: 1 << 0)
    public static let answered   = MessageFlags(rawValue: 1 << 1)
    public static let flagged    = MessageFlags(rawValue: 1 << 2)
    public static let draft      = MessageFlags(rawValue: 1 << 3)
    public static let deleted    = MessageFlags(rawValue: 1 << 4)
    public static let recent     = MessageFlags(rawValue: 1 << 5)
    public static let hasAttachment = MessageFlags(rawValue: 1 << 6)
}

/// Метаданные письма. Тело сюда **не** кладём — оно живёт в `MessageBody` и
/// никогда не пересекает границу persistence.
public struct Message: Sendable, Hashable, Identifiable, Codable {
    public struct ID: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }

    public let id: ID
    public let accountID: Account.ID
    public let mailboxID: Mailbox.ID
    public let uid: UInt32
    public let messageID: String?
    public let threadID: MessageThread.ID?
    public let subject: String
    public let from: MailAddress?
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let date: Date
    public let preview: String?
    public let size: Int
    public let flags: MessageFlags
    public let importance: Importance
    /// Значение заголовка List-Unsubscribe (метаданные, не тело письма).
    /// Формат: `<https://...>, <mailto:...>` — стандарт RFC 2369 / RFC 8058.
    /// nil, если заголовок отсутствует.
    public let listUnsubscribe: String?
    /// Значение заголовка List-Unsubscribe-Post (RFC 8058).
    /// Обычно содержит `List-Unsubscribe=One-Click` — признак поддержки POST-отписки.
    /// nil, если заголовок отсутствует или транспорт его не предоставляет.
    public let listUnsubscribePost: String?

    public init(
        id: ID,
        accountID: Account.ID,
        mailboxID: Mailbox.ID,
        uid: UInt32,
        messageID: String?,
        threadID: MessageThread.ID?,
        subject: String,
        from: MailAddress?,
        to: [MailAddress],
        cc: [MailAddress],
        date: Date,
        preview: String?,
        size: Int,
        flags: MessageFlags,
        importance: Importance,
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.mailboxID = mailboxID
        self.uid = uid
        self.messageID = messageID
        self.threadID = threadID
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.preview = preview
        self.size = size
        self.flags = flags
        self.importance = importance
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
    }
}
