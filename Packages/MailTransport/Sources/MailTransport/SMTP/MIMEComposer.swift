import Foundation

/// Компоновка исходящего MIME-сообщения (RFC 5322).
/// Формирует заголовки Message-ID, Date, From, To, Cc, Subject (RFC 2047),
/// Content-Type, Content-Transfer-Encoding и quoted-printable тело.
///
/// Только text/plain для v1.
public struct MIMEComposer: Sendable {

    /// Получатели сообщения. `bcc` не попадает в заголовки — только в SMTP envelope.
    public struct Recipients: Sendable {
        public let to: [String]
        public let cc: [String]
        public let bcc: [String]

        public init(to: [String], cc: [String] = [], bcc: [String] = []) {
            self.to = to
            self.cc = cc
            self.bcc = bcc
        }
    }

    /// Формирует готовое к отправке MIME-сообщение.
    ///
    /// - Parameters:
    ///   - from: Адрес отправителя — `"Name <email@example.com>"` или `"email@example.com"`
    ///   - recipients: To/Cc/Bcc-получатели (Bcc не пишется в заголовки)
    ///   - subject: Тема письма (кодируется RFC 2047 при наличии non-ASCII)
    ///   - body: Текст письма (plain text, quoted-printable)
    /// - Returns: Полное MIME-сообщение с CRLF-разделителями строк
    public static func compose(
        from: String,
        recipients: Recipients,
        subject: String,
        body: String
    ) -> String {
        let to = recipients.to
        let cc = recipients.cc
        _ = recipients.bcc
        var headers: [String] = []

        // Message-ID: <UUID@hostname>
        let hostname = ProcessInfo.processInfo.hostName
        let messageID = "<\(UUID().uuidString)@\(hostname)>"
        headers.append("Message-ID: \(messageID)")

        // Date: RFC 5322 — "Sun, 26 Apr 2026 20:00:00 +0000"
        headers.append("Date: \(formatRFC5322(Date()))")

        // From — passthrough
        headers.append("From: \(from)")

        // To — comma-separated
        headers.append("To: \(to.joined(separator: ", "))")

        // Cc — только при наличии
        if !cc.isEmpty {
            headers.append("Cc: \(cc.joined(separator: ", "))")
        }

        // Bcc — не включается в заголовки (передаётся только в SMTP-envelope)

        // Subject — RFC 2047 encoded-word при non-ASCII
        headers.append("Subject: \(encodeSubject(subject))")

        // Content headers
        headers.append("Content-Type: text/plain; charset=utf-8")
        headers.append("Content-Transfer-Encoding: quoted-printable")

        // Заголовки + пустая строка + тело
        let headerBlock = headers.joined(separator: "\r\n")
        let encodedBody = encodeQuotedPrintable(body)
        return "\(headerBlock)\r\n\r\n\(encodedBody)"
    }

    // MARK: - Date Formatting

    /// Форматирует дату в RFC 5322: `"Sun, 26 Apr 2026 20:00:00 +0300"`.
    private static func formatRFC5322(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    // MARK: - Subject Encoding (RFC 2047)

    /// Кодирует subject: ASCII — без изменений, иначе Base64 encoded-word.
    /// `=?utf-8?B?<base64>?=`
    private static func encodeSubject(_ subject: String) -> String {
        let isASCII = subject.allSatisfy { $0.isASCII }
        if isASCII {
            return subject
        }
        let base64 = Data(subject.utf8).base64EncodedString()
        return "=?utf-8?B?\(base64)?="
    }

    // MARK: - Quoted-Printable Encoding (RFC 2045 §6.7)

    /// Кодирует текст в quoted-printable.
    /// - Максимум 76 символов на строку, мягкий перенос `=\r\n`.
    /// - Non-ASCII и `=` кодируются как `=XX`.
    /// - Пробел/таб перед переносом строки кодируются как `=20`/`=09`.
    private static func encodeQuotedPrintable(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out = ""
        var lineLen = 0
        let maxLen = 76

        var idx = 0

        while idx < bytes.count {
            let b = bytes[idx]

            // ── Жёсткий перенос из входных данных ───────────
            if b == UInt8(ascii: "\r") || b == UInt8(ascii: "\n") {
                out += "\r\n"
                lineLen = 0
                if b == UInt8(ascii: "\r") && idx + 1 < bytes.count && bytes[idx + 1] == UInt8(ascii: "\n") {
                    idx += 2
                } else {
                    idx += 1
                }
                continue
            }

            // ── Определяем токен ─────────────────────────────
            // Look-ahead: следующий байт — конец строки?
            let nextIsEOL = (idx + 1 >= bytes.count)
                || (bytes[idx + 1] == UInt8(ascii: "\r"))
                || (bytes[idx + 1] == UInt8(ascii: "\n"))

            let token: String
            if b == UInt8(ascii: "=") {
                // = всегда кодируется
                token = "=3D"
            } else if (b == UInt8(ascii: " ") || b == UInt8(ascii: "\t")) && nextIsEOL {
                // Пробел/таб перед концом строки → кодируем
                token = (b == UInt8(ascii: " ")) ? "=20" : "=09"
            } else if (b >= 33 && b <= 126) || b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") {
                // Печатный ASCII + пробел/таб (не в конце строки), кроме = (обработан выше)
                token = String(UnicodeScalar(b))
            } else {
                // Всё остальное — =XX
                token = "=" + String(format: "%02X", b)
            }

            // ── Мягкий перенос при необходимости ─────────────
            // Резервируем 1 символ для `=` soft-break маркера, чтобы строка
            // вместе с `=` не превысила maxLen.
            if lineLen + token.count > maxLen - 1 {
                // Перед мягким переносом: пробел/таб в конце строки → закодировать
                if out.hasSuffix(String(UnicodeScalar(UInt8(ascii: " ")))) {
                    out = String(out.dropLast()) + "=20"
                    lineLen += 2
                } else if out.hasSuffix(String(UnicodeScalar(UInt8(ascii: "\t")))) {
                    out = String(out.dropLast()) + "=09"
                    lineLen += 2
                }
                out += "=\r\n"
                lineLen = 0
            }

            out += token
            lineLen += token.count
            idx += 1
        }

        return out
    }
}
