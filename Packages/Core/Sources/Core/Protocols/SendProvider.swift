import Foundation

/// SMTP-конверт исходящего письма. Содержит только то, что попадает в
/// SMTP-команды `MAIL FROM` / `RCPT TO` — то есть набор «сырых»
/// e-mail-адресов без display-name и без RFC 2047-кодирования.
///
/// `bcc` живёт только в этом конверте — в заголовки письма не попадает
/// (см. `MIMEBody.headers` / `MIMEComposer`).
public struct Envelope: Sendable, Hashable {
    /// Адрес отправителя (envelope From). Обычно совпадает с `From:` заголовком письма.
    public let from: String
    /// To-получатели.
    public let to: [String]
    /// Cc-получатели.
    public let cc: [String]
    /// Bcc-получатели — попадают только в SMTP-команды, не в заголовки.
    public let bcc: [String]

    public init(from: String, to: [String], cc: [String] = [], bcc: [String] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
    }

    /// Полный список получателей для `RCPT TO` (to + cc + bcc).
    public var recipients: [String] {
        to + cc + bcc
    }
}

/// Готовое к передаче по SMTP MIME-сообщение (RFC 5322).
///
/// На уровне Core — это просто строка: композиция выполняется
/// в `MailTransport.MIMEComposer` (RFC 5322 / 2047 / quoted-printable).
/// Тело сообщения держим в памяти и нигде на диск не сохраняем.
public struct MIMEBody: Sendable, Hashable {
    /// Полное MIME-сообщение, включая заголовки и пустую строку перед телом.
    /// Строки разделены CRLF.
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

/// Абстракция отправки писем. Реализация — `LiveSendProvider`
/// (SwiftNIO + SMTPConnection); моки могут отдавать заглушку.
///
/// Реализация обязана:
/// - не логировать содержимое `body` и адресов получателей;
/// - брать пароль/токен из `SecretsStore`, не передавать наружу;
/// - закрывать SMTP-сессию по завершении вызова.
public protocol SendProvider: Sendable {
    /// Отправляет письмо: выполняет SMTP-обмен MAIL FROM/RCPT TO/DATA.
    /// - Parameters:
    ///   - envelope: SMTP-конверт (from + to/cc/bcc).
    ///   - body: готовое MIME-сообщение.
    func send(envelope: Envelope, body: MIMEBody) async throws
}
