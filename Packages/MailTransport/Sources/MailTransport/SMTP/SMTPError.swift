import Foundation

/// Категоризованные ошибки SMTP-клиента.
/// Каждая категория соответствует отдельной фазе SMTP-сессии.
public enum SMTPError: Error, Sendable, Hashable {
    /// Ошибка TCP/TLS подключения (соединение не установлено).
    case connection(String)
    /// Неверные учётные данные (535 Authentication credentials invalid).
    case authenticationFailed(String)
    /// Метод аутентификации не поддерживается сервером (504/534).
    case authMethodNotSupported(String)
    /// Ошибка аутентификации (неверные учётные данные, метод не поддерживается).
    /// Устаревший вариант — используйте authenticationFailed / authMethodNotSupported.
    case authentication(String)
    /// Сервер отказал в relay — 55x коды, неверный получатель и т.п.
    case relay(Int, String)
    /// Ошибка TLS/SSL (handshake, сертификат).
    case tls(String)
    /// Неожиданный ответ сервера (нарушение RFC 5321).
    case unexpectedResponse(String)
    /// Канал закрыт раньше времени.
    case channelClosed
    /// Неожиданный код ответа.
    case unexpectedCode(Int, String)

    public static func == (lhs: SMTPError, rhs: SMTPError) -> Bool {
        switch (lhs, rhs) {
        case (.connection(let a), .connection(let b)): return a == b
        case (.authenticationFailed(let a), .authenticationFailed(let b)): return a == b
        case (.authMethodNotSupported(let a), .authMethodNotSupported(let b)): return a == b
        case (.authentication(let a), .authentication(let b)): return a == b
        case (.relay(let c1, let a), .relay(let c2, let b)): return c1 == c2 && a == b
        case (.tls(let a), .tls(let b)): return a == b
        case (.unexpectedResponse(let a), .unexpectedResponse(let b)): return a == b
        case (.channelClosed, .channelClosed): return true
        case (.unexpectedCode(let c1, let a), .unexpectedCode(let c2, let b)):
            return c1 == c2 && a == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .connection(let s): hasher.combine("conn"); hasher.combine(s)
        case .authenticationFailed(let s): hasher.combine("authFailed"); hasher.combine(s)
        case .authMethodNotSupported(let s): hasher.combine("authMethod"); hasher.combine(s)
        case .authentication(let s): hasher.combine("auth"); hasher.combine(s)
        case .relay(let c, let s): hasher.combine("relay"); hasher.combine(c); hasher.combine(s)
        case .tls(let s): hasher.combine("tls"); hasher.combine(s)
        case .unexpectedResponse(let s): hasher.combine("unexp"); hasher.combine(s)
        case .channelClosed: hasher.combine("closed")
        case .unexpectedCode(let c, let s): hasher.combine("code"); hasher.combine(c); hasher.combine(s)
        }
    }
}

extension SMTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connection(let s):
            return "Ошибка подключения SMTP: \(s)"
        case .authenticationFailed(let s):
            return "Неверные учётные данные SMTP: \(s)"
        case .authMethodNotSupported(let s):
            return "Метод аутентификации SMTP не поддерживается: \(s)"
        case .authentication(let s):
            return "Ошибка аутентификации SMTP: \(s)"
        case .relay(let code, let s):
            return "Сервер отказал в relay (\(code)): \(s)"
        case .tls(let s):
            return "Ошибка TLS SMTP: \(s)"
        case .unexpectedResponse(let s):
            return "Неожиданный ответ SMTP: \(s)"
        case .channelClosed:
            return "Соединение SMTP закрыто"
        case .unexpectedCode(let code, let s):
            return "Неожиданный код SMTP \(code): \(s)"
        }
    }
}
