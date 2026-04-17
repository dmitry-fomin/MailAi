import Foundation

/// Доменные ошибки почтового слоя. UI-слой матчит `enum`, транспорт — оборачивает
/// нативные в `.transport`. Сообщения безопасны для UI (без PII).
public enum MailError: Error, Sendable, Hashable {
    case network(Reason)
    case authentication(Reason)
    case tls(Reason)
    case protocolViolation(String)
    case messageNotFound(Message.ID)
    case mailboxNotFound(Mailbox.ID)
    case accountNotFound(Account.ID)
    case parsing(String)
    case cancelled
    case storage(Reason)
    case keychain(Reason)
    case unsupported(String)

    public enum Reason: String, Sendable, Hashable {
        case timeout
        case connectionLost
        case invalidCredentials
        case serverRejected
        case certificateInvalid
        case unknown
    }
}

extension MailError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .network(let r): return "Сетевая ошибка (\(r.rawValue))"
        case .authentication(let r): return "Ошибка авторизации (\(r.rawValue))"
        case .tls(let r): return "Ошибка TLS (\(r.rawValue))"
        case .protocolViolation(let s): return "Нарушение протокола: \(s)"
        case .messageNotFound: return "Письмо не найдено"
        case .mailboxNotFound: return "Папка не найдена"
        case .accountNotFound: return "Аккаунт не найден"
        case .parsing(let s): return "Ошибка разбора: \(s)"
        case .cancelled: return "Операция отменена"
        case .storage(let r): return "Ошибка хранилища (\(r.rawValue))"
        case .keychain(let r): return "Ошибка Keychain (\(r.rawValue))"
        case .unsupported(let s): return "Не поддерживается: \(s)"
        }
    }
}
