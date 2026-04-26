import Foundation

/// Разобранный SMTP-ответ (RFC 5321 §4.2).
/// Формат: `<code><space><text>` или `<code><hyphen><text>` (многострочный).
public struct SMTPResponse: Sendable, Hashable {
    /// Трёхзначный код ответа (200–599).
    public let code: Int
    /// Текстовая часть ответа.
    public let text: String
    /// Многострочный ли ответ (separator = `-`, а не пробел).
    public let isContinuation: Bool

    public init(code: Int, text: String, isContinuation: Bool = false) {
        self.code = code
        self.text = text
        self.isContinuation = isContinuation
    }

    /// Разбирает одну строку SMTP-ответа.
    /// - Ожидает формат: `250-SIZE 35882577` или `250 OK`.
    /// - Возвращает `nil` если строка не похожа на SMTP-ответ.
    public static func parse(_ line: String) -> SMTPResponse? {
        // Минимум: "XYZ " = 4 символа
        guard line.count >= 4 else { return nil }

        let digits = String(line.prefix(3))
        guard let code = Int(digits), code >= 100, code <= 599 else { return nil }

        let fourth = line.index(line.startIndex, offsetBy: 3)
        let rest = String(line[fourth...])

        // После кода: пробел = последняя строка, дефис = продолжение
        if rest.hasPrefix("-") {
            let text = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            return SMTPResponse(code: code, text: text, isContinuation: true)
        } else if rest.hasPrefix(" ") {
            let text = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            return SMTPResponse(code: code, text: text, isContinuation: false)
        }

        // Некоторые серверы отправляют только код без пробела
        return SMTPResponse(code: code, text: rest.trimmingCharacters(in: .whitespaces), isContinuation: false)
    }

    /// Категория ответа по первой цифре кода (RFC 5321 §4.2.1).
    public var category: Category {
        switch code / 100 {
        case 2: return .positiveCompletion
        case 3: return .positiveIntermediate
        case 4: return .transientNegative
        case 5: return .permanentNegative
        default: return .unknown
        }
    }

    public enum Category: Sendable {
        case positiveCompletion   // 2xx
        case positiveIntermediate // 3xx
        case transientNegative    // 4xx
        case permanentNegative    // 5xx
        case unknown
    }

    /// Успешный ли ответ (2xx или 3xx).
    public var isSuccess: Bool {
        code >= 200 && code < 400
    }
}
