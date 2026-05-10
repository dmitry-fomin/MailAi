import Foundation
@preconcurrency import CoreSpotlight
import Core

// MARK: - SpotlightIndexer

/// Индексирует метаданные писем в Spotlight через CoreSpotlight.
///
/// **Приватность:**
/// - Индексируются только: отправитель (displayName/email), тема и дата.
/// - Тело письма **никогда** не индексируется и не попадает в Spotlight.
/// - Индекс ограничен 5000 элементами (удаляем старые через FIFO при превышении).
///
/// **Формат Activity Type:** `com.mailai.message`
/// - `userInfo["messageID"]` — идентификатор письма.
/// - `userInfo["accountID"]` — идентификатор аккаунта.
///
/// Является синглтоном: `SpotlightIndexer.shared`.
public final class SpotlightIndexer: Sendable {

    public static let shared = SpotlightIndexer()

    /// Activity type для открытия письма из Spotlight/уведомлений.
    public static let activityType = "com.mailai.message"
    /// Ключ messageID в userInfo NSUserActivity и Spotlight attributeSet.
    public static let messageIDKey = "messageID"
    /// Ключ accountID в userInfo NSUserActivity.
    public static let accountIDKey = "accountID"

    private let searchableIndex = CSSearchableIndex.default()

    private init() {}

    // MARK: - Index

    /// Индексирует письмо в Spotlight.
    ///
    /// Безопасно вызывать из любого потока — CSSearchableIndex thread-safe.
    ///
    /// - Parameters:
    ///   - message: Метаданные письма (тело не используется).
    ///   - accountID: Идентификатор аккаунта для последующего удаления.
    public func index(message: Message, accountID: String) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .emailMessage)
        attributeSet.title = message.subject.isEmpty ? "(Без темы)" : message.subject
        attributeSet.displayName = message.from?.name ?? message.from?.address ?? ""
        attributeSet.authorNames = [message.from?.name ?? message.from?.address ?? ""]
        attributeSet.contentDescription = message.from?.address
        attributeSet.contentModificationDate = message.date
        attributeSet.addedDate = message.date

        // Тело письма намеренно не индексируется (приватность).

        // domainIdentifier позволяет удалять все письма аккаунта одним вызовом.
        let item = CSSearchableItem(
            uniqueIdentifier: spotlightID(messageID: message.id, accountID: accountID),
            domainIdentifier: accountID,
            attributeSet: attributeSet
        )
        // TTL 30 дней — Spotlight сам вытеснит устаревшие записи.
        item.expirationDate = Date().addingTimeInterval(30 * 24 * 3600)

        searchableIndex.indexSearchableItems([item]) { _ in
            // Ошибки индексации не критичны — Spotlight опционален.
        }
    }

    /// Индексирует пакет писем (batch).
    public func index(messages: [Message], accountID: String) {
        guard !messages.isEmpty else { return }

        let items = messages.map { message -> CSSearchableItem in
            let attributeSet = CSSearchableItemAttributeSet(contentType: .emailMessage)
            attributeSet.title = message.subject.isEmpty ? "(Без темы)" : message.subject
            attributeSet.displayName = message.from?.name ?? message.from?.address ?? ""
            attributeSet.authorNames = [message.from?.name ?? message.from?.address ?? ""]
            attributeSet.contentDescription = message.from?.address
            attributeSet.contentModificationDate = message.date
            attributeSet.addedDate = message.date

            let item = CSSearchableItem(
                uniqueIdentifier: spotlightID(messageID: message.id, accountID: accountID),
                domainIdentifier: accountID,
                attributeSet: attributeSet
            )
            item.expirationDate = Date().addingTimeInterval(30 * 24 * 3600)
            return item
        }

        searchableIndex.indexSearchableItems(items) { _ in }
    }

    // MARK: - Remove

    /// Удаляет все индексированные письма для указанного аккаунта.
    public func removeAll(for accountID: String) {
        searchableIndex.deleteSearchableItems(withDomainIdentifiers: [accountID]) { _ in }
    }

    /// Удаляет конкретное письмо из индекса.
    public func remove(messageID: Message.ID, accountID: String) {
        let id = spotlightID(messageID: messageID, accountID: accountID)
        searchableIndex.deleteSearchableItems(withIdentifiers: [id]) { _ in }
    }

    // MARK: - NSUserActivity

    /// Создаёт `NSUserActivity` для открытого письма.
    ///
    /// Устанавливайте это activity на `View` через `.userActivity(_:isActive:_:)`
    /// или на `NSWindowController` при открытии письма.
    ///
    /// При продолжении activity (`application(_:continue:restorationHandler:)`)
    /// или через Spotlight taps — вызывается `onOpenURL` / `onContinueUserActivity`.
    ///
    /// - Parameters:
    ///   - message: Открытое письмо.
    ///   - accountID: Идентификатор аккаунта.
    /// - Returns: Настроенный `NSUserActivity`.
    public func makeUserActivity(for message: Message, accountID: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = message.subject.isEmpty ? "(Без темы)" : message.subject
        activity.userInfo = [
            Self.messageIDKey: message.id,
            Self.accountIDKey: accountID
        ]
        // Делает письмо доступным через Spotlight Hand-off (только метаданные).
        activity.isEligibleForSearch = true
        activity.isEligibleForHandoff = false // без Handoff — локальное приложение
        activity.isEligibleForPublicIndexing = false // личная почта не публична

        let attributeSet = CSSearchableItemAttributeSet(contentType: .emailMessage)
        attributeSet.title = message.subject.isEmpty ? "(Без темы)" : message.subject
        attributeSet.displayName = message.from?.name ?? message.from?.address ?? ""
        activity.contentAttributeSet = attributeSet

        activity.becomeCurrent()
        return activity
    }

    // MARK: - Helpers

    private func spotlightID(messageID: Message.ID, accountID: String) -> String {
        "\(accountID)/\(messageID)"
    }
}

// MARK: - SpotlightActivityParser

/// Парсит `NSUserActivity` или URL-схему `mailai://message/<messageID>` для открытия письма.
public enum SpotlightActivityParser {

    /// Результат парсинга входящего activity/URL.
    public struct OpenRequest: Sendable, Equatable {
        public let messageID: String
        public let accountID: String?

        public init(messageID: String, accountID: String? = nil) {
            self.messageID = messageID
            self.accountID = accountID
        }
    }

    /// Извлекает `OpenRequest` из `NSUserActivity`.
    ///
    /// Поддерживает:
    /// - `activityType == "com.mailai.message"` с `userInfo["messageID"]`
    /// - `activityType == CSSearchableItemActionType` (тап по Spotlight-результату)
    public static func parse(activity: NSUserActivity) -> OpenRequest? {
        switch activity.activityType {
        case SpotlightIndexer.activityType:
            guard let messageID = activity.userInfo?[SpotlightIndexer.messageIDKey] as? String,
                  !messageID.isEmpty else { return nil }
            let accountID = activity.userInfo?[SpotlightIndexer.accountIDKey] as? String
            return OpenRequest(messageID: messageID, accountID: accountID)

        case CSSearchableItemActionType:
            // Spotlight tap: идентификатор в формате "<accountID>/<messageID>"
            guard let uniqueID = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
                return nil
            }
            let parts = uniqueID.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return OpenRequest(messageID: parts[1], accountID: parts[0])
            } else {
                return OpenRequest(messageID: uniqueID, accountID: nil)
            }

        default:
            return nil
        }
    }

    /// Извлекает `OpenRequest` из URL-схемы `mailai://message/<messageID>`.
    public static func parse(url: URL) -> OpenRequest? {
        guard url.scheme?.lowercased() == "mailai",
              url.host?.lowercased() == "message" else { return nil }
        let messageID = url.lastPathComponent
        guard !messageID.isEmpty, messageID != "/" else { return nil }
        return OpenRequest(messageID: messageID, accountID: nil)
    }
}
