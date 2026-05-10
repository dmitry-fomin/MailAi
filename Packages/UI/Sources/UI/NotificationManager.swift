import UserNotifications
import Foundation

// MARK: - Notification Action Identifiers

public enum MailNotificationAction {
    /// Идентификатор action «Отметить прочитанным».
    public static let markAsRead = "MAIL_MARK_AS_READ"
    /// Идентификатор category для уведомлений о письмах.
    public static let categoryID = "NEW_MAIL"
}

// MARK: - Notification Delegate

/// Делегат для отображения уведомлений, пока приложение в foreground,
/// и обработки action «Отметить прочитанным».
///
/// Регистрирует callback `onMarkAsRead`, который вызывается с `messageID`
/// когда пользователь тапает action в баннере. Привязка происходит в
/// `NotificationManager.setupDelegate(onMarkAsRead:)`.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    var onMarkAsRead: ((String) -> Void)?
    /// Вызывается при тапе на уведомление (action .defaultAction или кастомный tapped-баннер).
    var onOpenMessage: ((String) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let messageID = userInfo["messageID"] as? String

        switch response.actionIdentifier {
        case MailNotificationAction.markAsRead:
            if let messageID {
                onMarkAsRead?(messageID)
            }

        case UNNotificationDefaultActionIdentifier:
            // Пользователь тапнул по баннеру — открыть письмо.
            if let messageID {
                onOpenMessage?(messageID)
            }

        default:
            break
        }
    }
}

// MARK: - NotificationManager

/// Менеджер системных уведомлений с приватностью по умолчанию.
///
/// **Модель приватности:**
/// - Пока AI-pack не классифицировал письмо как важное, уведомление показывает
///   только generic-текст «Новое письмо в \<аккаунт\>».
/// - Если письмо помечено как важное — показываем subject + sender.
/// - Тело/сниппет письма **никогда** не попадают в уведомление.
///
/// **Action «Отметить прочитанным»:**
/// - Каждое уведомление содержит action `MailNotificationAction.markAsRead`.
/// - При нажатии вызывается callback, переданный в `setupDelegate(onMarkAsRead:)`.
/// - `messageID` передаётся через `userInfo["messageID"]`.
///
/// Используется как singleton: `NotificationManager.shared`.
public final class NotificationManager: @unchecked Sendable {

    public static let shared = NotificationManager()

    /// Делегат для foreground-уведомлений. Должен быть установлен один раз
    /// при запуске приложения.
    private let notificationDelegate = NotificationDelegate()

    /// Идентификаторы доставленных уведомлений, сгруппированные по `accountID`.
    private let lock = NSLock()
    private var deliveredIDs: [String: [String]] = [:]

    private init() {}

    /// Устанавливает делегат `UNUserNotificationCenter` и регистрирует
    /// notification category с action «Отметить прочитанным».
    ///
    /// Вызвать один раз при запуске приложения (из `AppDelegate` или `.task`).
    ///
    /// - Parameters:
    ///   - onMarkAsRead: Вызывается с `messageID`, когда пользователь нажимает
    ///     action «Отметить прочитанным» в баннере уведомления.
    ///   - onOpenMessage: Вызывается с `messageID`, когда пользователь тапает
    ///     по баннеру (тап без выбора action — открыть письмо).
    public func setupDelegate(
        onMarkAsRead: ((String) -> Void)? = nil,
        onOpenMessage: ((String) -> Void)? = nil
    ) {
        notificationDelegate.onMarkAsRead = onMarkAsRead
        notificationDelegate.onOpenMessage = onOpenMessage
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate

        // Регистрируем category с action «Отметить прочитанным».
        let markReadAction = UNNotificationAction(
            identifier: MailNotificationAction.markAsRead,
            title: "Отметить прочитанным",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: MailNotificationAction.categoryID,
            actions: [markReadAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Запрашивает у пользователя разрешение на показ уведомлений.
    /// Вызывается один раз — при добавлении первого аккаунта.
    /// - Returns: `true`, если разрешение получено.
    public func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    /// Показывает системное уведомление о новом письме.
    ///
    /// **Правила приватности:**
    /// - `isImportant == false`: generic «Новое письмо в \<accountName\>».
    ///   Не раскрывает тему, отправителя или содержимое.
    /// - `isImportant == true`: показывает sender в заголовке и subject в теле.
    /// - Тело/сниппет письма **никогда** не показываются.
    ///
    /// - Parameters:
    ///   - accountName: Отображаемое имя аккаунта (email или displayName).
    ///   - accountID: Уникальный идентификатор аккаунта. Используется для
    ///     группировки уведомлений (threadIdentifier) и их удаления.
    ///   - messageID: Идентификатор письма. Передаётся через `userInfo` для
    ///     последующей обработки action «Отметить прочитанным».
    ///   - subject: Тема письма (показывается только если `isImportant == true`).
    ///   - sender: Имя/адрес отправителя (показывается только если `isImportant == true`).
    ///   - isImportant: Признак того, что AI-pack одобрил письмо как важное.
    public func notify(
        accountName: String,
        accountID: String,
        messageID: String? = nil,
        subject: String? = nil,
        sender: String? = nil,
        isImportant: Bool = false
    ) {
        let content = UNMutableNotificationContent()

        if isImportant {
            // Важное письмо: показываем sender + subject (без тела/сниппета).
            content.title = sender ?? "Новое важное письмо"
            content.body = subject ?? "Откройте письмо, чтобы прочитать"
        } else {
            // Неважное / не классифицированное: generic без раскрытия данных.
            content.title = "MailAi"
            content.body = "Новое письмо в \(accountName)"
        }

        content.sound = .default
        // Группировка уведомлений по аккаунту в Notification Center.
        content.threadIdentifier = accountID
        // Category с action «Отметить прочитанным».
        content.categoryIdentifier = MailNotificationAction.categoryID
        // messageID передаём в userInfo для обработки action.
        if let messageID {
            content.userInfo = ["messageID": messageID]
        }

        let notificationID = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: nil // доставить немедленно
        )

        UNUserNotificationCenter.current().add(request)

        // Запоминаем ID для последующего удаления по аккаунту.
        lock.lock()
        deliveredIDs[accountID, default: []].append(notificationID)
        lock.unlock()
    }

    /// Удаляет все доставленные уведомления для указанного аккаунта.
    ///
    /// - Parameter accountID: Идентификатор аккаунта, ранее переданный
    ///   в вызов `notify(accountID:…)`.
    public func removeDeliveredNotifications(for accountID: String) {
        lock.lock()
        let ids = deliveredIDs.removeValue(forKey: accountID) ?? []
        lock.unlock()

        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ids
        )
    }
}
