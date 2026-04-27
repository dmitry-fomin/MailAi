import Foundation

/// SMTP-4: IMAP APPEND (RFC 3501 §6.3.11).
///
/// APPEND кладёт raw-сообщение в указанный mailbox (типичный сценарий —
/// сохранение черновика в Drafts). Команда состоит из двух фаз:
///
///   1. Клиент шлёт `APPEND <mailbox> [(flags)] [date-time] {N}\r\n`,
///      где `N` — длина литерала в октетах.
///   2. Сервер отвечает `+ ...` continuation.
///   3. Клиент шлёт литерал длиной ровно `N` байт + завершающий `\r\n`,
///      после чего сервер возвращает tagged-ответ.
///
/// Длина литерала считается в октетах UTF-8 (RFC 3501 не запрещает
/// non-ASCII, IMAP4rev1 сервера должны принимать 8-бит литерал).
extension IMAPConnection {

    /// Формирует первую строку APPEND-команды (без завершающего CRLF —
    /// его добавляет фрейм-кодек). Вынесено отдельно от `append(...)` чтобы
    /// логика построения команды была независимо тестируемой
    /// (см. `IMAPAppendSmoke`).
    ///
    /// - Parameters:
    ///   - mailbox: имя папки (будет заквочено).
    ///   - flags: список флагов (`["\\Draft", "\\Seen"]`). Пустой список → `(flags)` секция опускается.
    ///   - date: internal date в RFC 3501 формате `"dd-MMM-yyyy HH:mm:ss zzzz"`. `nil` → опускается.
    ///   - literalOctets: длина литерала в октетах.
    public static func formatAppendCommand(
        mailbox: String,
        flags: [String],
        date: String?,
        literalOctets: Int
    ) -> String {
        var parts: [String] = ["APPEND", quote(mailbox)]
        if !flags.isEmpty {
            parts.append("(\(flags.joined(separator: " ")))")
        }
        if let date {
            parts.append(quote(date))
        }
        parts.append("{\(literalOctets)}")
        return parts.joined(separator: " ")
    }

    /// RFC 3501 §6.3.11: APPEND mailbox [(flags)] [date-time] {literal}.
    ///
    /// Литерал передаётся как UTF-8 байты. Сообщение в `literal` должно
    /// быть валидным RFC 5322 MIME с CRLF-разделителями строк (см. `MIMEComposer`).
    ///
    /// - Parameters:
    ///   - mailbox: целевая папка (например, путь Drafts из `LIST`).
    ///   - flags: системные/пользовательские флаги. Для черновиков обычно `["\\Draft"]`.
    ///   - date: internal date (RFC 3501); `nil` → сервер выставит `now`.
    ///   - literal: тело сообщения. Не логируется.
    /// - Throws: `IMAPConnectionError` при сетевой ошибке или NO/BAD от сервера.
    public func append(
        mailbox: String,
        flags: [String] = [],
        date: String? = nil,
        literal: String
    ) async throws {
        let octets = literal.utf8.count
        let header = Self.formatAppendCommand(
            mailbox: mailbox,
            flags: flags,
            date: date,
            literalOctets: octets
        )
        let tag = await tagGenerator.next()
        try await _writeOutbound(IMAPLine("\(tag) \(header)"))

        // Ждём `+` continuation. По пути могут прийти untagged-уведомления —
        // их игнорируем, но если получили tagged с нашим tag'ом раньше
        // continuation — сервер отверг команду (NO/BAD).
        while true {
            guard let line = try await _readNext() else {
                throw IMAPConnectionError.channelClosed
            }
            switch IMAPParser.parse(line.raw) {
            case .continuation:
                // OK, шлём литерал.
                try await _writeOutbound(IMAPLine(literal))
                // После литерала ждём финальный tagged-ответ.
                while let next = try await _readNext() {
                    switch IMAPParser.parse(next.raw) {
                    case .tagged(let t) where t.tag == tag:
                        guard t.status == .ok else {
                            throw IMAPConnectionError.commandFailed(
                                status: t.status, text: t.text
                            )
                        }
                        return
                    default:
                        continue
                    }
                }
                throw IMAPConnectionError.channelClosed
            case .tagged(let t) where t.tag == tag:
                throw IMAPConnectionError.commandFailed(
                    status: t.status, text: t.text
                )
            case .tagged, .untagged:
                continue
            }
        }
    }
}
