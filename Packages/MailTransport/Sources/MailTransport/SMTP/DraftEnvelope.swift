import Foundation

/// SMTP-4: envelope черновика письма для сохранения через IMAP APPEND.
///
/// Содержит ровно те поля, которые нужны MIMEComposer'у: from + получатели + subject.
/// Тело передаётся отдельно (не хранится здесь, чтобы не задерживать в памяти
/// дольше необходимого — провайдер компонует MIME и сразу отдаёт в APPEND).
public struct DraftEnvelope: Sendable, Equatable {
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String

    public init(
        from: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
    }

    /// Преобразует в `MIMEComposer.Recipients` (без bcc — для черновика
    /// bcc-заголовка обычно нет, но если хочется его сохранить — добавим
    /// при отправке через SMTP-3, не здесь).
    public var recipients: MIMEComposer.Recipients {
        MIMEComposer.Recipients(to: to, cc: cc, bcc: bcc)
    }
}
