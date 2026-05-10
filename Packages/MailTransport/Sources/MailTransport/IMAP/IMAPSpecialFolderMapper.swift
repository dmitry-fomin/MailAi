import Foundation

// MARK: - Special folder kinds

/// Тип специальной папки IMAP.
public enum IMAPSpecialFolder: String, Sendable, CaseIterable, Equatable {
    case inbox   = "INBOX"
    case sent    = "Sent"
    case drafts  = "Drafts"
    case trash   = "Trash"
    case archive = "Archive"
    case spam    = "Spam"
}

// MARK: - Mapping result

/// Маппинг специальных папок для одного аккаунта.
/// `nil` — папка не найдена на сервере.
public struct IMAPSpecialFolderMap: Sendable, Equatable {
    public var inbox: String?
    public var sent: String?
    public var drafts: String?
    public var trash: String?
    public var archive: String?
    public var spam: String?

    public init(
        inbox: String? = nil,
        sent: String? = nil,
        drafts: String? = nil,
        trash: String? = nil,
        archive: String? = nil,
        spam: String? = nil
    ) {
        self.inbox = inbox
        self.sent = sent
        self.drafts = drafts
        self.trash = trash
        self.archive = archive
        self.spam = spam
    }

    /// Возвращает путь для указанного типа папки.
    public func path(for kind: IMAPSpecialFolder) -> String? {
        switch kind {
        case .inbox:   return inbox
        case .sent:    return sent
        case .drafts:  return drafts
        case .trash:   return trash
        case .archive: return archive
        case .spam:    return spam
        }
    }

    /// Применяет пользовательский override — если передан непустой путь,
    /// он заменяет обнаруженный.
    public mutating func applyOverride(for kind: IMAPSpecialFolder, path: String?) {
        guard let path, !path.isEmpty else { return }
        switch kind {
        case .inbox:   inbox = path
        case .sent:    sent = path
        case .drafts:  drafts = path
        case .trash:   trash = path
        case .archive: archive = path
        case .spam:    spam = path
        }
    }
}

// MARK: - Detector

/// Определяет специальные папки IMAP через SPECIAL-USE (RFC 6154) и fallback
/// на хорошо известные имена.
///
/// Порядок приоритетов:
/// 1. XLIST (Gmail extension) / LIST с флагами SPECIAL-USE.
/// 2. Fallback на хорошо известные имена (Sent Items, Sent Messages, Junk и т.д.).
/// 3. INBOX всегда "INBOX" как минимум.
///
/// Не хранит состояние — используйте как утилиту.
public enum IMAPSpecialFolderMapper {

    // MARK: - Public

    /// Определяет специальные папки через LIST + SPECIAL-USE флаги.
    ///
    /// Шаги:
    /// 1. Запрашивает `LIST "" "*"` (или XLIST если ответ приходит с Gmail-флагами).
    /// 2. Разбирает SPECIAL-USE атрибуты (`\Sent`, `\Drafts`, `\Trash`, `\Archive`, `\Junk`).
    /// 3. Для незаполненных — применяет `wellKnownFallback`.
    /// 4. INBOX всегда присутствует.
    public static func detect(
        connection: IMAPConnection,
        overrides: [IMAPSpecialFolder: String] = [:]
    ) async throws -> IMAPSpecialFolderMap {
        // Получаем список папок.
        let entries = try await connection.list()

        var map = buildFromSpecialUse(entries: entries)

        // INBOX — всегда присутствует.
        map.inbox = "INBOX"

        // Fallback для незаполненных.
        applyWellKnownFallback(entries: entries, map: &map)

        // Применяем пользовательские overrides.
        for (kind, path) in overrides {
            map.applyOverride(for: kind, path: path)
        }

        return map
    }

    // MARK: - SPECIAL-USE parsing

    /// Разбирает SPECIAL-USE флаги из LIST-ответов (RFC 6154).
    ///
    /// Поддерживаемые атрибуты:
    /// - `\Sent` → sent
    /// - `\Drafts` → drafts
    /// - `\Trash` → trash
    /// - `\Archive` → archive
    /// - `\Junk` → spam
    /// - `\Spam` → spam (нестандартный, но распространённый)
    /// - `\AllMail` → игнорируем (Gmail All Mail)
    /// - `\Important` → игнорируем
    public static func buildFromSpecialUse(entries: [ListEntry]) -> IMAPSpecialFolderMap {
        var map = IMAPSpecialFolderMap()
        for entry in entries {
            let flags = entry.flags.map { $0.lowercased() }
            if flags.contains("\\sent") || flags.contains("\\sentmail") {
                if map.sent == nil { map.sent = entry.path }
            }
            if flags.contains("\\drafts") || flags.contains("\\draft") {
                if map.drafts == nil { map.drafts = entry.path }
            }
            if flags.contains("\\trash") || flags.contains("\\deleted") {
                if map.trash == nil { map.trash = entry.path }
            }
            if flags.contains("\\archive") {
                if map.archive == nil { map.archive = entry.path }
            }
            if flags.contains("\\junk") || flags.contains("\\spam") {
                if map.spam == nil { map.spam = entry.path }
            }
        }
        return map
    }

    // MARK: - Well-known name fallback

    /// Хорошо известные имена папок для провайдеров без SPECIAL-USE.
    private static let wellKnownSent: Set<String> = [
        "Sent", "Sent Items", "Sent Messages", "Sent Mail",
        "SENT", "Отправленные", "已发送邮件"
    ]

    private static let wellKnownDrafts: Set<String> = [
        "Drafts", "Draft", "DRAFTS",
        "Черновики", "Entwürfe"
    ]

    private static let wellKnownTrash: Set<String> = [
        "Trash", "Deleted Items", "Deleted Messages",
        "TRASH", "Корзина", "Papierkorb", "已删除邮件"
    ]

    private static let wellKnownArchive: Set<String> = [
        "Archive", "Archives", "All Mail", "ARCHIVE",
        "Архив"
    ]

    private static let wellKnownSpam: Set<String> = [
        "Spam", "Junk", "Junk Email", "Junk E-mail",
        "SPAM", "JUNK", "Спам"
    ]

    /// Применяет fallback по хорошо известным именам для незаполненных полей.
    public static func applyWellKnownFallback(entries: [ListEntry], map: inout IMAPSpecialFolderMap) {
        for entry in entries {
            // Проверяем только последний компонент пути (leaf name).
            let leaf = leafName(of: entry.path)

            if map.sent == nil, wellKnownSent.contains(leaf) {
                map.sent = entry.path
            }
            if map.drafts == nil, wellKnownDrafts.contains(leaf) {
                map.drafts = entry.path
            }
            if map.trash == nil, wellKnownTrash.contains(leaf) {
                map.trash = entry.path
            }
            if map.archive == nil, wellKnownArchive.contains(leaf) {
                map.archive = entry.path
            }
            if map.spam == nil, wellKnownSpam.contains(leaf) {
                map.spam = entry.path
            }
        }
    }

    // MARK: - Helpers

    /// Возвращает последний компонент пути (после последнего разделителя).
    static func leafName(of path: String) -> String {
        // Разделители: `/`, `.`, `|` — наиболее распространённые.
        for sep in ["/", ".", "|"] {
            if let idx = path.lastIndex(of: sep.first!) {
                let after = path.index(after: idx)
                if after < path.endIndex {
                    return String(path[after...])
                }
            }
        }
        return path
    }
}
