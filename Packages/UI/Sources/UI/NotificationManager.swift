import UserNotifications
import Foundation

// MARK: - Notification Delegate

/// Делегат для отображения уведомлений, пока приложение в foreground.
/// Без него macOS глушит баннеры, если окно активно.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
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

    /// Устанавливает делегат `UNUserNotificationCenter`.
    /// Вызвать один раз при запуске приложения (из `AppDelegate` или `.task`).
    public func setupDelegate() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
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
    ///   - subject: Тема письма (показывается только если `isImportant == true`).
    ///   - sender: Имя/адрес отправителя (показывается только если `isImportant == true`).
    ///   - isImportant: Признак того, что AI-pack одобрил письмо как важное.
    public func notify(
        accountName: String,
        accountID: String,
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
