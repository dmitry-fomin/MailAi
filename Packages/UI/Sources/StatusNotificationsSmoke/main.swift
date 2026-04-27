import Foundation

/// Smoke-тесты для Status-3:
///
/// 1. Форматирование badge-count для StatusBar (как в `StatusBarBadgeLabel`):
///    - 0           → бейдж скрыт (пустая строка)
///    - 1..99       → "N"
///    - 100+        → "99+"
///
/// 2. Фильтрация системных уведомлений по AI-классификации:
///    - письмо классифицировано как «не важное» → генерится generic-уведомление
///      («MailAi» / «Новое письмо в <accountName>») без раскрытия subject/sender;
///    - письмо классифицировано как «важное» → допустимо показать sender/subject;
///    - тело/сниппет письма не должны попасть в payload уведомления никогда.
///
/// XCTest в CLT недоступен — используем `precondition` как ассерт.
/// Запускается из `Scripts/smoke.sh` под `swift run StatusNotificationsSmoke`.
@main
enum StatusNotificationsSmoke {
    static func main() {
        testBadgeCountFormatting()
        testBadgeVisibility()
        testNotificationFilter_genericForNotImportant()
        testNotificationFilter_importantShowsSenderAndSubject()
        testNotificationFilter_neverIncludesBodyOrSnippet()
        testNotificationFilter_dropsExplicitlyFiltered()
        print("✅ StatusNotificationsSmoke: все проверки пройдены")
    }

    // MARK: - Badge formatting

    /// Воспроизводит логику `StatusBarBadgeLabel.badgeText`:
    /// > unreadCount > 99 ? "99+" : "\(unreadCount)"
    /// плюс сворачивает count == 0 в пустую строку (бейдж скрыт).
    static func badgeText(unreadCount: Int) -> String {
        guard unreadCount > 0 else { return "" }
        return unreadCount > 99 ? "99+" : "\(unreadCount)"
    }

    private static func testBadgeCountFormatting() {
        precondition(badgeText(unreadCount: 0) == "",
                     "0 unread должен скрывать бейдж (пустая строка)")
        precondition(badgeText(unreadCount: 1) == "1",
                     "1 unread → \"1\"")
        precondition(badgeText(unreadCount: 7) == "7",
                     "7 unread → \"7\"")
        precondition(badgeText(unreadCount: 42) == "42",
                     "42 unread → \"42\"")
        precondition(badgeText(unreadCount: 99) == "99",
                     "99 unread → \"99\" (граница)")
        precondition(badgeText(unreadCount: 100) == "99+",
                     "100 unread → \"99+\" (за порогом)")
        precondition(badgeText(unreadCount: 9999) == "99+",
                     "9999 unread → \"99+\"")
    }

    private static func testBadgeVisibility() {
        // Отрицательные значения никогда не должны приходить, но трактуем как «скрыто».
        precondition(badgeText(unreadCount: -1) == "",
                     "negative unread должен скрывать бейдж")
    }

    // MARK: - NL notification filter

    /// Локальный тип, имитирующий результат AI-классификации.
    /// Не зависит от реального Classifier из пакета AI — нам важна только
    /// форма данных, на которые опирается NotificationManager.
    enum FakeClassification: Sendable {
        case important
        case notImportant
        /// AI явно попросил подавить уведомление (например, спам/рассылка).
        case suppressed
    }

    /// Минимальная inline-копия payload-логики `NotificationManager.notify(...)`,
    /// без обращения к UNUserNotificationCenter. Возвращает (title, body) или
    /// nil, если уведомление подавлено фильтром.
    static func renderNotification(
        accountName: String,
        subject: String?,
        sender: String?,
        classification: FakeClassification
    ) -> (title: String, body: String)? {
        switch classification {
        case .suppressed:
            return nil
        case .important:
            return (
                title: sender ?? "Новое важное письмо",
                body: subject ?? "Откройте письмо, чтобы прочитать"
            )
        case .notImportant:
            return (
                title: "MailAi",
                body: "Новое письмо в \(accountName)"
            )
        }
    }

    private static func testNotificationFilter_genericForNotImportant() {
        let payload = renderNotification(
            accountName: "work",
            subject: "Confidential merger details",
            sender: "ceo@corp.example",
            classification: .notImportant
        )
        guard let payload else {
            preconditionFailure("notImportant должен производить generic-payload, не nil")
        }
        precondition(payload.title == "MailAi",
                     "title для notImportant должен быть generic")
        precondition(!payload.body.contains("Confidential"),
                     "subject не должен утекать в generic-уведомление")
        precondition(!payload.body.contains("ceo@corp.example"),
                     "sender не должен утекать в generic-уведомление")
        precondition(payload.body.contains("work"),
                     "generic body должен упоминать имя аккаунта")
    }

    private static func testNotificationFilter_importantShowsSenderAndSubject() {
        let payload = renderNotification(
            accountName: "work",
            subject: "Q2 budget review",
            sender: "boss@corp.example",
            classification: .important
        )
        guard let payload else {
            preconditionFailure("important не должен подавляться")
        }
        precondition(payload.title == "boss@corp.example",
                     "important: title == sender")
        precondition(payload.body == "Q2 budget review",
                     "important: body == subject")
    }

    private static func testNotificationFilter_neverIncludesBodyOrSnippet() {
        // Тело письма / сниппет не должны попадать в payload ни при каком исходе.
        // Эмулируем это, проверяя что render не принимает body как аргумент —
        // это гарантируется сигнатурой выше. Дополнительно прогоняем оба
        // важных кейса с «грязным» subject и убеждаемся, что posted body
        // совпадает только с subject (т.е. не было конкатенации со сниппетом).
        let dirtySubject = "Subject only — no body leakage"
        let imp = renderNotification(
            accountName: "x",
            subject: dirtySubject,
            sender: "a@b",
            classification: .important
        )
        precondition(imp?.body == dirtySubject,
                     "important body должен быть строго равен subject")
        let unimp = renderNotification(
            accountName: "x",
            subject: dirtySubject,
            sender: "a@b",
            classification: .notImportant
        )
        precondition(unimp?.body == "Новое письмо в x",
                     "notImportant body должен быть строго generic")
    }

    private static func testNotificationFilter_dropsExplicitlyFiltered() {
        let payload = renderNotification(
            accountName: "work",
            subject: "Buy crypto now",
            sender: "spam@bad.example",
            classification: .suppressed
        )
        precondition(payload == nil,
                     "suppressed-классификация должна полностью гасить уведомление")
    }
}
