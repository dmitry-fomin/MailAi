import Foundation

public indirect enum IMAPValue: Sendable, Equatable {
    case nilValue
    case atom(String)
    case number(UInt64)
    case quoted(String)
    case literal(String)
    case list([IMAPValue])

    public var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }

    public var stringValue: String? {
        switch self {
        case .quoted(let s), .literal(let s), .atom(let s): return s
        case .number(let n): return String(n)
        case .nilValue, .list: return nil
        }
    }

    public var listValue: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    public var numberValue: UInt64? {
        switch self {
        case .number(let n): return n
        case .atom(let s), .quoted(let s), .literal(let s): return UInt64(s)
        case .nilValue, .list: return nil
        }
    }
}

public enum IMAPParseError: Error, Equatable, Sendable {
    case unexpectedEnd
    case unexpectedCharacter(Unicode.Scalar)
    case invalidLiteral
    case invalidNumber
    case malformedEnvelope
    case malformedBodyStructure
    case malformedFetch
}

public struct IMAPValueTokenizer: Sendable {
    private let chars: [Unicode.Scalar]
    private var index: Int = 0

    public init(_ input: String) {
        self.chars = Array(input.unicodeScalars)
    }

    public static func parse(_ input: String) throws -> [IMAPValue] {
        var tokenizer = IMAPValueTokenizer(input)
        var values: [IMAPValue] = []
        tokenizer.skipWhitespace()
        while !tokenizer.isAtEnd {
            values.append(try tokenizer.parseValue())
            tokenizer.skipWhitespace()
        }
        return values
    }

    public static func parseList(_ input: String) throws -> [IMAPValue] {
        var tokenizer = IMAPValueTokenizer(input)
        tokenizer.skipWhitespace()
        guard !tokenizer.isAtEnd else { return [] }
        let value = try tokenizer.parseValue()
        guard case .list(let items) = value else {
            throw IMAPParseError.unexpectedCharacter(tokenizer.peek() ?? Unicode.Scalar(32))
        }
        return items
    }

    private var isAtEnd: Bool { index >= chars.count }

    private func peek() -> Unicode.Scalar? {
        index < chars.count ? chars[index] : nil
    }

    private mutating func advance() -> Unicode.Scalar {
        let c = chars[index]
        index += 1
        return c
    }

    private mutating func skipWhitespace() {
        while index < chars.count, chars[index] == " " || chars[index] == "\t" {
            index += 1
        }
    }

    private mutating func parseValue() throws -> IMAPValue {
        skipWhitespace()
        guard let c = peek() else { throw IMAPParseError.unexpectedEnd }
        switch c {
        case "(":
            return try parseList()
        case "\"":
            return try parseQuoted()
        case "{":
            return try parseLiteral()
        default:
            return try parseAtomOrNumber()
        }
    }

    private mutating func parseList() throws -> IMAPValue {
        _ = advance()
        var items: [IMAPValue] = []
        skipWhitespace()
        while let c = peek(), c != ")" {
            items.append(try parseValue())
            skipWhitespace()
        }
        guard !isAtEnd else { throw IMAPParseError.unexpectedEnd }
        _ = advance()
        return .list(items)
    }

    private mutating func parseQuoted() throws -> IMAPValue {
        _ = advance()
        var result = ""
        while let c = peek() {
            if c == "\\" {
                _ = advance()
                guard let next = peek() else { throw IMAPParseError.unexpectedEnd }
                result.unicodeScalars.append(next)
                _ = advance()
            } else if c == "\"" {
                _ = advance()
                return .quoted(result)
            } else {
                result.unicodeScalars.append(c)
                _ = advance()
            }
        }
        throw IMAPParseError.unexpectedEnd
    }

    private mutating func parseLiteral() throws -> IMAPValue {
        _ = advance()
        var digits = ""
        while let c = peek(), c != "}" {
            digits.unicodeScalars.append(c)
            _ = advance()
        }
        guard !isAtEnd else { throw IMAPParseError.invalidLiteral }
        _ = advance()
        if let c = peek(), c == "\r" { _ = advance() }
        if let c = peek(), c == "\n" { _ = advance() }
        guard let length = Int(digits) else { throw IMAPParseError.invalidLiteral }
        // IMAP RFC 3501: литерал '{N}' содержит ровно N ОКТЕТОВ (байтов).
        // Итерируем по Unicode.Scalar, но считаем потреблённые байты UTF-8,
        // чтобы правильно обрезать литерал на многобайтовых символах
        // (кириллица = 2 байта/scalar, CJK = 3 байта/scalar).
        var collected = ""
        var byteCount = 0
        while byteCount < length, index < chars.count {
            let ch = chars[index]
            let chBytes = Int(ch.utf8.count)
            // Не добавляем символ, если он выходит за пределы литерала.
            guard byteCount + chBytes <= length else { break }
            collected.unicodeScalars.append(ch)
            byteCount += chBytes
            index += 1
        }
        return .literal(collected)
    }

    private mutating func parseAtomOrNumber() throws -> IMAPValue {
        var buf = ""
        while let c = peek() {
            if c == " " || c == "\t" || c == "(" || c == ")" || c == "[" || c == "]" {
                break
            }
            buf.unicodeScalars.append(c)
            _ = advance()
        }
        if buf.isEmpty { throw IMAPParseError.unexpectedEnd }
        if buf.uppercased() == "NIL" { return .nilValue }
        if let n = UInt64(buf) { return .number(n) }
        return .atom(buf)
    }
}

public struct IMAPAddress: Sendable, Equatable {
    public let name: String?
    public let adl: String?
    public let mailbox: String?
    public let host: String?

    public init(name: String?, adl: String?, mailbox: String?, host: String?) {
        self.name = name
        self.adl = adl
        self.mailbox = mailbox
        self.host = host
    }

    public var address: String? {
        guard let mailbox, let host else { return nil }
        return "\(mailbox)@\(host)"
    }

    static func parse(_ value: IMAPValue) -> IMAPAddress? {
        guard case .list(let items) = value, items.count == 4 else { return nil }
        return IMAPAddress(
            name: items[0].stringValue.map(IMAPHeaderDecoder.decode),
            adl: items[1].stringValue,
            mailbox: items[2].stringValue,
            host: items[3].stringValue
        )
    }

    static func parseList(_ value: IMAPValue) -> [IMAPAddress] {
        guard case .list(let items) = value else { return [] }
        return items.compactMap(IMAPAddress.parse)
    }
}

public struct IMAPEnvelope: Sendable, Equatable {
    public let date: String?
    public let subject: String?
    public let from: [IMAPAddress]
    public let sender: [IMAPAddress]
    public let replyTo: [IMAPAddress]
    public let to: [IMAPAddress]
    public let cc: [IMAPAddress]
    public let bcc: [IMAPAddress]
    public let inReplyTo: String?
    public let messageID: String?

    public init(date: String?, subject: String?, from: [IMAPAddress], sender: [IMAPAddress],
                replyTo: [IMAPAddress], to: [IMAPAddress], cc: [IMAPAddress], bcc: [IMAPAddress],
                inReplyTo: String?, messageID: String?) {
        self.date = date
        self.subject = subject
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.messageID = messageID
    }

    public static func parse(_ value: IMAPValue) throws -> IMAPEnvelope {
        guard case .list(let items) = value, items.count >= 10 else {
            throw IMAPParseError.malformedEnvelope
        }
        return IMAPEnvelope(
            date: items[0].stringValue,
            subject: items[1].stringValue.map(IMAPHeaderDecoder.decode),
            from: IMAPAddress.parseList(items[2]),
            sender: IMAPAddress.parseList(items[3]),
            replyTo: IMAPAddress.parseList(items[4]),
            to: IMAPAddress.parseList(items[5]),
            cc: IMAPAddress.parseList(items[6]),
            bcc: IMAPAddress.parseList(items[7]),
            inReplyTo: items[8].stringValue,
            messageID: items[9].stringValue
        )
    }
}

public indirect enum IMAPBodyStructure: Sendable, Equatable {
    case singlePart(IMAPBodyPart)
    case multiPart(IMAPMultipart)

    public var isMultipart: Bool {
        if case .multiPart = self { return true }
        return false
    }

    public static func parse(_ value: IMAPValue) throws -> IMAPBodyStructure {
        guard case .list(let items) = value, !items.isEmpty else {
            throw IMAPParseError.malformedBodyStructure
        }
        if case .list = items[0] {
            return try parseMultipart(items)
        }
        return try parseSinglePart(items)
    }

    private static func parseSinglePart(_ items: [IMAPValue]) throws -> IMAPBodyStructure {
        guard items.count >= 7 else { throw IMAPParseError.malformedBodyStructure }
        let type = items[0].stringValue ?? ""
        let subtype = items[1].stringValue ?? ""
        let params = parseParams(items[2])
        let id = items[3].stringValue
        let description = items[4].stringValue
        let encoding = items[5].stringValue ?? "7BIT"
        let size = items[6].numberValue ?? 0
        return .singlePart(IMAPBodyPart(
            type: type, subtype: subtype, parameters: params,
            id: id, description: description, encoding: encoding, size: size
        ))
    }

    private static func parseMultipart(_ items: [IMAPValue]) throws -> IMAPBodyStructure {
        var parts: [IMAPBodyStructure] = []
        var subtype = ""
        var index = 0
        while index < items.count {
            if case .list(let sub) = items[index], !sub.isEmpty, case .list = sub[0] {
                parts.append(try parse(items[index]))
                index += 1
                continue
            }
            if case .list = items[index] {
                parts.append(try parse(items[index]))
                index += 1
                continue
            }
            subtype = items[index].stringValue ?? ""
            index += 1
            break
        }
        return .multiPart(IMAPMultipart(subtype: subtype, parts: parts))
    }

    private static func parseParams(_ value: IMAPValue) -> [String: String] {
        guard case .list(let items) = value else { return [:] }
        var result: [String: String] = [:]
        var i = 0
        while i + 1 < items.count {
            if let key = items[i].stringValue, let val = items[i + 1].stringValue {
                result[key.lowercased()] = val
            }
            i += 2
        }
        return result
    }
}

public struct IMAPBodyPart: Sendable, Equatable {
    public let type: String
    public let subtype: String
    public let parameters: [String: String]
    public let id: String?
    public let description: String?
    public let encoding: String
    public let size: UInt64

    public init(type: String, subtype: String, parameters: [String: String],
                id: String?, description: String?, encoding: String, size: UInt64) {
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.id = id
        self.description = description
        self.encoding = encoding
        self.size = size
    }

    public var mimeType: String { "\(type.lowercased())/\(subtype.lowercased())" }
}

public struct IMAPMultipart: Sendable, Equatable {
    public let subtype: String
    public let parts: [IMAPBodyStructure]

    public init(subtype: String, parts: [IMAPBodyStructure]) {
        self.subtype = subtype
        self.parts = parts
    }
}

public struct IMAPMessageFlags: Sendable, Equatable, OptionSet {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let seen      = IMAPMessageFlags(rawValue: 1 << 0)
    public static let answered  = IMAPMessageFlags(rawValue: 1 << 1)
    public static let flagged   = IMAPMessageFlags(rawValue: 1 << 2)
    public static let deleted   = IMAPMessageFlags(rawValue: 1 << 3)
    public static let draft     = IMAPMessageFlags(rawValue: 1 << 4)
    public static let recent    = IMAPMessageFlags(rawValue: 1 << 5)

    public static func parse(_ tokens: [String]) -> (system: IMAPMessageFlags, keywords: [String]) {
        var flags: IMAPMessageFlags = []
        var keywords: [String] = []
        for token in tokens where !token.isEmpty {
            switch token {
            case "\\Seen":     flags.insert(.seen)
            case "\\Answered": flags.insert(.answered)
            case "\\Flagged":  flags.insert(.flagged)
            case "\\Deleted":  flags.insert(.deleted)
            case "\\Draft":    flags.insert(.draft)
            case "\\Recent":   flags.insert(.recent)
            default:
                if !token.hasPrefix("\\") { keywords.append(token) }
            }
        }
        return (flags, keywords)
    }
}

public struct IMAPFetchResponse: Sendable, Equatable {
    public let sequenceNumber: UInt32
    public let uid: UInt32?
    public let flags: IMAPMessageFlags
    public let keywords: [String]
    public let internalDate: String?
    public let rfc822Size: UInt64?
    public let envelope: IMAPEnvelope?
    public let bodyStructure: IMAPBodyStructure?
    public let attributes: [String: IMAPValue]

    public init(sequenceNumber: UInt32, uid: UInt32?, flags: IMAPMessageFlags,
                keywords: [String], internalDate: String?, rfc822Size: UInt64?,
                envelope: IMAPEnvelope?, bodyStructure: IMAPBodyStructure?,
                attributes: [String: IMAPValue]) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        self.flags = flags
        self.keywords = keywords
        self.internalDate = internalDate
        self.rfc822Size = rfc822Size
        self.envelope = envelope
        self.bodyStructure = bodyStructure
        self.attributes = attributes
    }

    public static func parse(_ untagged: IMAPUntaggedResponse) throws -> IMAPFetchResponse {
        try parse(raw: untagged.raw)
    }

    public static func parse(raw: String) throws -> IMAPFetchResponse {
        let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let seq = UInt32(parts[0]),
              parts[1].uppercased() == "FETCH" else {
            throw IMAPParseError.malformedFetch
        }
        let payload = String(parts[2])
        let parsed = try IMAPValueTokenizer.parse(payload)
        guard let first = parsed.first, case .list(let pairs) = first else {
            throw IMAPParseError.malformedFetch
        }
        return try parsePairs(sequenceNumber: seq, pairs: pairs)
    }

    private static func parsePairs(sequenceNumber: UInt32, pairs: [IMAPValue]) throws -> IMAPFetchResponse {
        var uid: UInt32?
        var flags: IMAPMessageFlags = []
        var keywords: [String] = []
        var internalDate: String?
        var size: UInt64?
        var envelope: IMAPEnvelope?
        var body: IMAPBodyStructure?
        var attributes: [String: IMAPValue] = [:]
        var i = 0
        while i + 1 < pairs.count {
            let key = (pairs[i].stringValue ?? "").uppercased()
            let value = pairs[i + 1]
            switch key {
            case "UID":
                uid = value.numberValue.flatMap { UInt32(exactly: $0) }
            case "FLAGS":
                if case .list(let items) = value {
                    let tokens = items.compactMap(\.stringValue)
                    let parsed = IMAPMessageFlags.parse(tokens)
                    flags = parsed.system
                    keywords = parsed.keywords
                }
            case "INTERNALDATE":
                internalDate = value.stringValue
            case "RFC822.SIZE":
                size = value.numberValue
            case "ENVELOPE":
                envelope = try IMAPEnvelope.parse(value)
            case "BODYSTRUCTURE", "BODY":
                if case .list = value {
                    body = try IMAPBodyStructure.parse(value)
                }
            default:
                attributes[key] = value
            }
            i += 2
        }
        return IMAPFetchResponse(
            sequenceNumber: sequenceNumber,
            uid: uid,
            flags: flags,
            keywords: keywords,
            internalDate: internalDate,
            rfc822Size: size,
            envelope: envelope,
            bodyStructure: body,
            attributes: attributes
        )
    }
}

public enum IMAPHeaderDecoder: Sendable {
    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "=", input.index(after: i) < input.endIndex, input[input.index(after: i)] == "?" {
                if let end = findEncodedWordEnd(in: input, from: i),
                   let decoded = decodeWord(String(input[i...end])) {
                    result.append(decoded)
                    let after = input.index(after: end)
                    var skip = after
                    while skip < input.endIndex, input[skip] == " " || input[skip] == "\t" {
                        skip = input.index(after: skip)
                    }
                    if skip < input.endIndex, input[skip] == "=",
                       input.index(after: skip) < input.endIndex,
                       input[input.index(after: skip)] == "?" {
                        i = skip
                    } else {
                        i = after
                    }
                    continue
                }
            }
            result.append(input[i])
            i = input.index(after: i)
        }
        return result
    }

    private static func findEncodedWordEnd(in s: String, from start: String.Index) -> String.Index? {
        var qcount = 0
        var i = start
        while i < s.endIndex {
            if s[i] == "?" {
                qcount += 1
                if qcount == 4 {
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] == "=" {
                        return next
                    }
                    return nil
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func decodeWord(_ word: String) -> String? {
        guard word.hasPrefix("=?"), word.hasSuffix("?=") else { return nil }
        let inner = word.dropFirst(2).dropLast(2)
        let parts = inner.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = String(parts[0]).lowercased()
        let encoding = String(parts[1]).uppercased()
        let payload = String(parts[2])
        let data: Data?
        switch encoding {
        case "B":
            data = Data(base64Encoded: payload)
        case "Q":
            data = decodeQ(payload)
        default:
            return nil
        }
        guard let bytes = data else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let s = String(data: bytes, encoding: String.Encoding(rawValue: nsEncoding)) {
                return s
            }
        }
        return String(data: bytes, encoding: .utf8)
    }

    private static func decodeQ(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "_" {
                out.append(0x20)
                i = s.index(after: i)
            } else if ch == "=" {
                let h1 = s.index(after: i)
                guard h1 < s.endIndex else { break }
                let h2 = s.index(after: h1)
                guard h2 < s.endIndex else { break }
                let hex = String(s[h1...h2])
                if let byte = UInt8(hex, radix: 16) { out.append(byte) }
                i = s.index(after: h2)
            } else {
                out.append(contentsOf: String(ch).utf8)
                i = s.index(after: i)
            }
        }
        return out
    }
}
