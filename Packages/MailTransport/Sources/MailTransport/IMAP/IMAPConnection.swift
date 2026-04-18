import Foundation
import NIOCore
import NIOPosix

public enum IMAPConnectionError: Error, Equatable, Sendable {
    case greetingMissing
    case unexpectedGreeting(String)
    case channelClosed
    case commandFailed(status: IMAPResponseStatus, text: String)
}

/// Высокоуровневая IMAP-сессия. Живёт строго внутри замыкания
/// `withOpen(...) { conn in ... }` — это соответствует
/// `NIOAsyncChannel.executeThenClose` scoping.
///
/// Не Sendable: один writer/один reader. Вызовы `execute`-методов
/// подразумеваются серийными в рамках одной Task.
public final class IMAPConnection: @unchecked Sendable {
    public let tagGenerator = IMAPTagGenerator()
    public let greeting: IMAPUntaggedResponse

    private var iterator: NIOAsyncChannelInboundStream<IMAPLine>.AsyncIterator
    private let outbound: NIOAsyncChannelOutboundWriter<IMAPLine>

    public typealias Channel = NIOAsyncChannel<IMAPLine, IMAPLine>

    /// Открывает TCP+TLS соединение, читает greeting, передаёт `IMAPConnection`
    /// в замыкание. Канал гарантированно закрыт после выхода.
    public static func withOpen<R>(
        endpoint: IMAPEndpoint,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton,
        connectTimeout: TimeAmount = .seconds(10),
        _ body: (IMAPConnection) async throws -> R
    ) async throws -> R {
        let channel = try await IMAPClientBootstrap.connect(
            to: endpoint,
            eventLoopGroup: eventLoopGroup,
            connectTimeout: connectTimeout
        )
        return try await withOpen(channel: channel, body)
    }

    public static func withOpen<R>(
        channel: Channel,
        _ body: (IMAPConnection) async throws -> R
    ) async throws -> R {
        try await channel.executeThenClose { inbound, outbound in
            var iter = inbound.makeAsyncIterator()
            guard let line = try await iter.next() else {
                throw IMAPConnectionError.greetingMissing
            }
            guard case .untagged(let greeting) = IMAPParser.parse(line.raw) else {
                throw IMAPConnectionError.unexpectedGreeting(line.raw)
            }
            let kind = greeting.kind
            guard kind == "OK" || kind == "PREAUTH" else {
                throw IMAPConnectionError.unexpectedGreeting(line.raw)
            }
            let connection = IMAPConnection(
                greeting: greeting,
                iterator: iter,
                outbound: outbound
            )
            return try await body(connection)
        }
    }

    fileprivate init(
        greeting: IMAPUntaggedResponse,
        iterator: NIOAsyncChannelInboundStream<IMAPLine>.AsyncIterator,
        outbound: NIOAsyncChannelOutboundWriter<IMAPLine>
    ) {
        self.greeting = greeting
        self.iterator = iterator
        self.outbound = outbound
    }

    /// Отправляет команду с очередным тегом и читает ответы до tagged.
    public func execute(_ command: String) async throws -> IMAPCommandResult {
        let tag = await tagGenerator.next()
        try await outbound.write(IMAPLine("\(tag) \(command)"))

        var untagged: [IMAPUntaggedResponse] = []
        while let incoming = try await iterator.next() {
            switch IMAPParser.parse(incoming.raw) {
            case .untagged(let u):
                untagged.append(u)
            case .tagged(let t) where t.tag == tag:
                return IMAPCommandResult(tagged: t, untagged: untagged)
            case .tagged:
                continue
            case .continuation:
                continue
            }
        }
        throw IMAPConnectionError.channelClosed
    }

    // MARK: - Typed commands

    public func capability() async throws -> [String] {
        let result = try await execute("CAPABILITY")
        try checkOK(result.tagged)
        return result.untagged
            .first { $0.kind == "CAPABILITY" }?
            .raw
            .split(separator: " ")
            .dropFirst()
            .map(String.init) ?? []
    }

    public func login(username: String, password: String) async throws {
        let quoted = "\(Self.quote(username)) \(Self.quote(password))"
        let result = try await execute("LOGIN \(quoted)")
        try checkOK(result.tagged)
    }

    public func list(reference: String = "", pattern: String = "*") async throws -> [ListEntry] {
        let result = try await execute("LIST \(Self.quote(reference)) \(Self.quote(pattern))")
        try checkOK(result.tagged)
        return result.untagged.compactMap(ListEntry.parse)
    }

    public func select(_ mailbox: String) async throws -> SelectResult {
        let result = try await execute("SELECT \(Self.quote(mailbox))")
        try checkOK(result.tagged)
        return SelectResult.parse(untagged: result.untagged, taggedText: result.tagged.text)
    }

    public func logout() async throws {
        _ = try? await execute("LOGOUT")
    }

    /// B8: IDLE (RFC 2177). Отправляет `IDLE`, ждёт `+ continuation`, затем
    /// читает untagged-события и передаёт их в `onEvent` до отмены задачи
    /// или ошибки канала. По `CancellationError` отправляет `DONE` и ждёт
    /// финальный tagged OK. Реконнект и re-IDLE каждые 29 мин — зона
    /// ответственности `IMAPReconnectSupervisor` поверх этого примитива.
    @discardableResult
    public func idle(
        onEvent: (IMAPUntaggedResponse) -> Void = { _ in }
    ) async throws -> IMAPTaggedResponse {
        let tag = await tagGenerator.next()
        try await outbound.write(IMAPLine("\(tag) IDLE"))

        // Ждём первую строку: либо continuation "+ idling", либо tagged
        // (сервер отказал), либо untagged-событие.
        guard let first = try await iterator.next() else {
            throw IMAPConnectionError.channelClosed
        }
        switch IMAPParser.parse(first.raw) {
        case .tagged(let t) where t.tag == tag:
            return t
        case .untagged(let u):
            onEvent(u)
        case .tagged, .continuation:
            break
        }

        do {
            while true {
                try Task.checkCancellation()
                guard let line = try await iterator.next() else {
                    throw IMAPConnectionError.channelClosed
                }
                switch IMAPParser.parse(line.raw) {
                case .tagged(let t) where t.tag == tag:
                    return t
                case .untagged(let u):
                    onEvent(u)
                case .tagged, .continuation:
                    continue
                }
            }
        } catch is CancellationError {
            try await outbound.write(IMAPLine("DONE"))
            while let line = try await iterator.next() {
                switch IMAPParser.parse(line.raw) {
                case .tagged(let t) where t.tag == tag:
                    return t
                case .untagged(let u):
                    onEvent(u)
                default:
                    continue
                }
            }
            throw IMAPConnectionError.channelClosed
        }
    }

    /// B6: UID FETCH для диапазона — возвращает распарсенные FETCH-ответы.
    /// Untagged-линии, которые не являются FETCH (EXISTS, RECENT и т.п.),
    /// игнорируются. Ошибки парсинга отдельных строк — пропускаются, чтобы
    /// одна «кривая» запись не ломала всю синхронизацию; счётчик таких
    /// ошибок возвращается во втором поле тупла.
    public func uidFetchHeaders(
        range: IMAPUIDRange,
        attributes: String = IMAPFetchAttributes.headers
    ) async throws -> (fetches: [IMAPFetchResponse], parseErrors: Int) {
        let cmd = IMAPFetchAttributes.uidFetchCommand(range: range, attributes: attributes)
        let result = try await execute(cmd)
        try checkOK(result.tagged)

        var fetches: [IMAPFetchResponse] = []
        var parseErrors = 0
        for u in result.untagged {
            // Untagged вида "N FETCH (...)" — разбираем. Всё прочее игнор.
            let parts = u.raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[1].uppercased() == "FETCH" else { continue }
            do {
                fetches.append(try IMAPFetchResponse.parse(u))
            } catch {
                parseErrors += 1
            }
        }
        return (fetches, parseErrors)
    }

    // MARK: - Internal bridge (для IMAPBodyStream)

    /// Internal hook: пишет одну линию в outbound. Используется стримингом тела,
    /// чтобы не дублировать логику `execute()`.
    func _writeOutbound(_ line: IMAPLine) async throws {
        try await outbound.write(line)
    }

    /// Internal hook: читает следующую линию из inbound. mutating — нужен для
    /// продвижения AsyncIterator. Вызывающая сторона обязана выполнять вызовы
    /// строго последовательно из одного Task (как и в `execute`).
    func _readNext() async throws -> IMAPLine? {
        try await iterator.next()
    }

    // MARK: - Helpers

    private func checkOK(_ tagged: IMAPTaggedResponse) throws {
        guard tagged.status == .ok else {
            throw IMAPConnectionError.commandFailed(
                status: tagged.status, text: tagged.text
            )
        }
    }

    static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Parsed structures

public struct ListEntry: Sendable, Equatable {
    public let flags: [String]
    public let delimiter: String?
    public let path: String

    public init(flags: [String], delimiter: String?, path: String) {
        self.flags = flags
        self.delimiter = delimiter
        self.path = path
    }

    public static func parse(_ untagged: IMAPUntaggedResponse) -> ListEntry? {
        guard untagged.kind == "LIST" else { return nil }
        let body = untagged.raw.dropFirst("LIST".count).trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("("),
              let closeIdx = body.firstIndex(of: ")") else { return nil }
        let flagsSub = body[body.index(after: body.startIndex)..<closeIdx]
        let flags = flagsSub.split(separator: " ").map(String.init)
        let rest = body[body.index(after: closeIdx)...].trimmingCharacters(in: .whitespaces)
        let tokens = Self.tokenize(String(rest))
        guard tokens.count >= 2 else { return nil }
        let delim: String? = tokens[0] == "NIL" ? nil : tokens[0]
        let path = tokens[1]
        return ListEntry(flags: flags, delimiter: delim, path: path)
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" {
                if inQuotes {
                    tokens.append(current)
                    current = ""
                }
                inQuotes.toggle()
            } else if ch == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

public struct SelectResult: Sendable, Equatable {
    public let exists: Int
    public let recent: Int
    public let uidValidity: UInt32?
    public let uidNext: UInt32?
    public let flags: [String]
    public let readOnly: Bool

    public init(exists: Int = 0, recent: Int = 0, uidValidity: UInt32? = nil,
                uidNext: UInt32? = nil, flags: [String] = [], readOnly: Bool = false) {
        self.exists = exists
        self.recent = recent
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.flags = flags
        self.readOnly = readOnly
    }

    static func parse(untagged: [IMAPUntaggedResponse], taggedText: String) -> SelectResult {
        var exists = 0
        var recent = 0
        var uidValidity: UInt32?
        var uidNext: UInt32?
        var flags: [String] = []
        for u in untagged {
            let parts = u.raw.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, let n = Int(parts[0]) {
                if parts[1].uppercased() == "EXISTS" { exists = n }
                else if parts[1].uppercased() == "RECENT" { recent = n }
            }
            if u.kind == "OK" {
                if let v = Self.extractBracketed(u.raw, key: "UIDVALIDITY") {
                    uidValidity = UInt32(v)
                }
                if let v = Self.extractBracketed(u.raw, key: "UIDNEXT") {
                    uidNext = UInt32(v)
                }
            }
            if u.kind == "FLAGS" {
                let body = u.raw.dropFirst("FLAGS".count).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("("), let close = body.firstIndex(of: ")") {
                    let inside = body[body.index(after: body.startIndex)..<close]
                    flags = inside.split(separator: " ").map(String.init)
                }
            }
        }
        let readOnly = taggedText.contains("[READ-ONLY]")
        return SelectResult(exists: exists, recent: recent,
                            uidValidity: uidValidity, uidNext: uidNext,
                            flags: flags, readOnly: readOnly)
    }

    private static func extractBracketed(_ text: String, key: String) -> String? {
        guard let open = text.range(of: "[\(key) ") else { return nil }
        let afterKey = text[open.upperBound...]
        guard let close = afterKey.firstIndex(of: "]") else { return nil }
        return String(afterKey[..<close])
    }
}
