import Foundation

/// AI-7: серверная синхронизация «Отфильтрованных» папок.
///
/// Содержит чистые helper'ы — генерацию имён mailbox-ов, выбор разделителя
/// иерархии, формат IMAP-команд CREATE/MOVE — без сетевого ввода-вывода.
/// Это упрощает тестирование (smoke без живого соединения).
///
/// Имена папок: `MailAi/Important` и `MailAi/Unimportant`. Если у сервера
/// разделитель не `/` (например, Dovecot с `.`), он подставляется в качестве
/// сепаратора корневого префикса. Имена локализовать не нужно — это
/// технические идентификаторы.
public enum IMAPServerFolderSync {

    /// Целевая папка для синхронизации классификации.
    public enum Target: String, Sendable, Equatable, CaseIterable {
        case important
        case unimportant
    }

    /// Корневой префикс «контейнера» приложения. По нему UI показывает,
    /// что папки управляются MailAi.
    public static let rootPrefix: String = "MailAi"

    /// Имя дочерней папки (фиксированное, не локализуем).
    public static func leafName(for target: Target) -> String {
        switch target {
        case .important:    return "Important"
        case .unimportant:  return "Unimportant"
        }
    }

    /// Полный путь mailbox-а с учётом разделителя.
    /// `delimiter == nil` — fallback на `/`.
    public static func path(for target: Target, delimiter: String?) -> String {
        let sep = (delimiter?.isEmpty == false) ? delimiter! : "/"
        return rootPrefix + sep + leafName(for: target)
    }

    /// Команда `CREATE` для конкретной цели. Используется для smoke-проверок,
    /// чтобы убедиться, что строка совпадает с ожидаемой формой RFC 3501.
    public static func createCommand(for target: Target, delimiter: String?) -> String {
        let path = path(for: target, delimiter: delimiter)
        return "CREATE \"\(escape(path))\""
    }

    /// Команда `UID MOVE` для одного UID — для smoke-проверок RFC 6851.
    public static func uidMoveCommand(uid: UInt32, target: Target, delimiter: String?) -> String {
        let path = path(for: target, delimiter: delimiter)
        return "UID MOVE \(uid) \"\(escape(path))\""
    }

    /// Эквивалент IMAPConnection.quote: экранирует `\` и `"`.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
