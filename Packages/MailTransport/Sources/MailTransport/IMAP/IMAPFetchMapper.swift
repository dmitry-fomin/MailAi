import Foundation
import Core

/// Маппер `IMAPFetchResponse → Core.Message`. Занимается только преобразованием
/// структуры: IMAP-флаги → `MessageFlags`, адреса → `MailAddress`,
/// INTERNALDATE → `Date`. Тела не трогает (B7).
public enum IMAPFetchMapper {
    /// Превращает FETCH-ответ в доменную `Message`. Возвращает nil, если в
    /// ответе нет UID — без него письмо нельзя стабильно идентифицировать и
    /// переживать expunge.
    public static func toMessage(
        _ fetch: IMAPFetchResponse,
        accountID: Account.ID,
        mailboxID: Mailbox.ID,
        fallbackDate: Date = Date()
    ) -> Message? {
        guard let uid = fetch.uid else { return nil }
        let envelope = fetch.envelope
        let id = Message.ID("\(mailboxID.rawValue):\(uid)")
        let hasAttachment = bodyStructureHasAttachment(fetch.bodyStructure)

        return Message(
            id: id,
            accountID: accountID,
            mailboxID: mailboxID,
            uid: uid,
            messageID: envelope?.messageID,
            threadID: nil,
            subject: envelope?.subject ?? "(без темы)",
            from: envelope?.from.first.flatMap(mailAddress(_:)),
            to: envelope?.to.compactMap(mailAddress(_:)) ?? [],
            cc: envelope?.cc.compactMap(mailAddress(_:)) ?? [],
            date: parseInternalDate(fetch.internalDate) ?? parseRFC2822Date(envelope?.date) ?? fallbackDate,
            preview: nil,
            size: Int(fetch.rfc822Size ?? 0),
            flags: convertFlags(fetch.flags, hasAttachment: hasAttachment),
            importance: .unknown
        )
    }

    // MARK: - Private helpers

    private static func mailAddress(_ a: IMAPAddress) -> MailAddress? {
        guard let addr = a.address else { return nil }
        return MailAddress(address: addr, name: a.name)
    }

    private static func convertFlags(_ imapFlags: IMAPMessageFlags, hasAttachment: Bool) -> MessageFlags {
        var result: MessageFlags = []
        if imapFlags.contains(.seen)     { result.insert(.seen) }
        if imapFlags.contains(.answered) { result.insert(.answered) }
        if imapFlags.contains(.flagged)  { result.insert(.flagged) }
        if imapFlags.contains(.draft)    { result.insert(.draft) }
        if imapFlags.contains(.deleted)  { result.insert(.deleted) }
        if imapFlags.contains(.recent)   { result.insert(.recent) }
        if hasAttachment { result.insert(.hasAttachment) }
        return result
    }

    private static func bodyStructureHasAttachment(_ body: IMAPBodyStructure?) -> Bool {
        guard let body else { return false }
        switch body {
        case .singlePart(let part):
            return isAttachmentMime(type: part.type, subtype: part.subtype, params: part.parameters)
        case .multiPart(let mp):
            return mp.parts.contains(where: { bodyStructureHasAttachment($0) })
        }
    }

    private static func isAttachmentMime(type: String, subtype: String, params: [String: String]) -> Bool {
        // «Вложение» — всё, что не text/*. В multipart text/html + text/plain
        // — это тело; PDF/изображения/офис — вложения. Плюс если есть имя
        // файла, считаем вложением независимо от типа.
        if params["name"] != nil || params["filename"] != nil { return true }
        let t = type.lowercased()
        return t != "text" && t != "multipart"
    }

    /// `DateFormatter` не является thread-safe при конкурентном вызове
    /// `date(from:)`. Создаём экземпляр локально внутри каждого вызова —
    /// это дороже static singleton, но безопасно при строгой конкурентности
    /// без `@MainActor`. Инициализация DateFormatter лёгкая (< 1 мкс), поэтому
    /// overhead пренебрежимо мал на фоне сетевых операций.
    public static func parseInternalDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        // IMAP INTERNALDATE: "17-Apr-2026 10:30:42 +0300"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: s)
    }

    public static func parseRFC2822Date(_ s: String?) -> Date? {
        guard let s else { return nil }
        // RFC2822: "Tue, 17 Apr 2026 10:30:42 +0300"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: s)
    }
}
