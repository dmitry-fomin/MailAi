import Foundation

/// Подпись пользователя, добавляемая при создании нового письма / ответе.
///
/// Тело подписи (`body`) — plain text; HTML-версия строится на уровне
/// UI (SwiftUI TextEditor). Тело **не является телом письма** и хранится
/// в таблице `signature` (метаданные/настройки), что соответствует
/// инварианту CLAUDE.md (тела писем на диске — запрещены; подписи — нет).
///
/// `accountID` — привязка подписи к аккаунту. `nil` означает глобальную
/// подпись (используется при открытии нового письма, если для аккаунта
/// нет явно назначенной подписи).
public struct Signature: Sendable, Hashable, Identifiable, Codable {

    // MARK: - ID

    public struct ID: Sendable, Hashable, Codable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }

    // MARK: - Properties

    /// Уникальный идентификатор.
    public let id: ID

    /// Отображаемое имя, например «Рабочая», «Личная».
    public let name: String

    /// Plain-text содержимое подписи.
    public let body: String

    /// Используется ли подпись по умолчанию при создании нового письма.
    public let isDefault: Bool

    /// Привязка к конкретному аккаунту (по `Account.ID`).
    /// `nil` — подпись глобальная, доступна для всех аккаунтов.
    public let accountID: Account.ID?

    // MARK: - Init

    public init(
        id: ID = ID(UUID().uuidString),
        name: String,
        body: String,
        isDefault: Bool = false,
        accountID: Account.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.isDefault = isDefault
        self.accountID = accountID
    }
}
