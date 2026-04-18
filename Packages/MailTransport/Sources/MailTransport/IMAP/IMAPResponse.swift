import Foundation

/// Категория IMAP-ответа.
public enum IMAPResponseStatus: String, Sendable, Equatable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
    case bye = "BYE"
    case preauth = "PREAUTH"
}

/// Один тegged ответ сервера (`<tag> <status> <text>`).
public struct IMAPTaggedResponse: Sendable, Equatable {
    public let tag: String
    public let status: IMAPResponseStatus
    public let text: String

    public init(tag: String, status: IMAPResponseStatus, text: String) {
        self.tag = tag
        self.status = status
        self.text = text
    }
}

/// Untagged-ответ (`*`) — содержит любые промежуточные данные: CAPABILITY,
/// EXISTS, LIST, FETCH, BYE и т.п.
public struct IMAPUntaggedResponse: Sendable, Equatable {
    public let raw: String

    public init(raw: String) { self.raw = raw }

    /// Первое слово после `*` — тип untagged-ответа.
    public var kind: String {
        raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }
}

/// Итог выполнения IMAP-команды: финальный статус + собранные untagged-ответы.
public struct IMAPCommandResult: Sendable, Equatable {
    public let tagged: IMAPTaggedResponse
    public let untagged: [IMAPUntaggedResponse]

    public init(tagged: IMAPTaggedResponse, untagged: [IMAPUntaggedResponse]) {
        self.tagged = tagged
        self.untagged = untagged
    }

    public var isOK: Bool { tagged.status == .ok }
}

/// Парсер строки IMAP. Отличает tagged/untagged/continuation.
public enum IMAPParser {
    public enum Line: Sendable, Equatable {
        case untagged(IMAPUntaggedResponse)
        case tagged(IMAPTaggedResponse)
        case continuation(String)  // +
    }

    public static func parse(_ line: String) -> Line {
        if line.hasPrefix("* ") {
            return .untagged(IMAPUntaggedResponse(raw: String(line.dropFirst(2))))
        }
        if line.hasPrefix("+") {
            let rest = line.dropFirst().drop(while: { $0 == " " })
            return .continuation(String(rest))
        }
        // Tagged: tag SPACE status SPACE text
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let tag = parts.count > 0 ? String(parts[0]) : ""
        let statusRaw = parts.count > 1 ? String(parts[1]) : ""
        let text = parts.count > 2 ? String(parts[2]) : ""
        let status = IMAPResponseStatus(rawValue: statusRaw) ?? .bad
        return .tagged(IMAPTaggedResponse(tag: tag, status: status, text: text))
    }
}
