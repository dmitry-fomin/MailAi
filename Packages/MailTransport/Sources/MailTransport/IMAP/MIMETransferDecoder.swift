import Foundation

/// Стриминговые декодеры Content-Transfer-Encoding.
///
/// Каждый декодер обрабатывает поток байтов по чанкам: при `feed(_:)`
/// возвращает декодированные байты, буферизуя незавершённые последовательности
/// до следующего вызова. По завершении — `finish()`.
public protocol MIMEStreamingDecoder: AnyObject {
    func feed(_ bytes: [UInt8]) -> [UInt8]
    func finish() -> [UInt8]
}

/// Identity (7bit / 8bit / binary): байты отдаются без изменений.
public final class MIMEIdentityDecoder: MIMEStreamingDecoder {
    public init() {}
    public func feed(_ bytes: [UInt8]) -> [UInt8] { bytes }
    public func finish() -> [UInt8] { [] }
}

/// Quoted-Printable (RFC 2045 §6.7). Поддерживает:
/// - `=XX` hex-последовательности;
/// - мягкие переносы `=\r\n` и `=\n` (пропускаются);
/// - неполный хвост (`=` без двух hex-цифр) — буферизуется до следующего feed.
public final class MIMEQuotedPrintableDecoder: MIMEStreamingDecoder {
    private var pending: [UInt8] = []

    public init() {}

    public func feed(_ bytes: [UInt8]) -> [UInt8] {
        var input = pending
        input.append(contentsOf: bytes)
        pending.removeAll(keepingCapacity: true)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)

        var i = 0
        while i < input.count {
            let b = input[i]
            if b == UInt8(ascii: "=") {
                // Нужно минимум 2 символа после '='.
                if i + 2 >= input.count {
                    pending.append(contentsOf: input[i...])
                    return out
                }
                let c1 = input[i + 1]
                let c2 = input[i + 2]
                if c1 == UInt8(ascii: "\r") && c2 == UInt8(ascii: "\n") {
                    // soft line break
                    i += 3
                    continue
                }
                if c1 == UInt8(ascii: "\n") {
                    i += 2
                    continue
                }
                if let h1 = Self.hex(c1), let h2 = Self.hex(c2) {
                    out.append(UInt8(h1 << 4 | h2))
                    i += 3
                } else {
                    // Некорректная последовательность: отдаём символы «как есть»
                    // (толерантность к кривым письмам).
                    out.append(b)
                    i += 1
                }
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    public func finish() -> [UInt8] {
        let tail = pending
        pending.removeAll()
        return tail
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}

/// Base64 (RFC 4648). Игнорирует пробелы, CR, LF; буферизует незавершённую
/// 4-байтовую группу до следующего feed.
public final class MIMEBase64Decoder: MIMEStreamingDecoder {
    private var quartet: [UInt8] = []
    private var finished = false

    public init() {}

    public func feed(_ bytes: [UInt8]) -> [UInt8] {
        guard !finished else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count * 3) / 4 + 3)

        for b in bytes {
            if b == UInt8(ascii: " ") || b == UInt8(ascii: "\r") ||
                b == UInt8(ascii: "\n") || b == UInt8(ascii: "\t") { continue }
            quartet.append(b)
            if quartet.count == 4 {
                if let decoded = Self.decodeQuartet(quartet) {
                    out.append(contentsOf: decoded)
                }
                if quartet.contains(UInt8(ascii: "=")) {
                    finished = true
                }
                quartet.removeAll(keepingCapacity: true)
                if finished { break }
            }
        }
        return out
    }

    public func finish() -> [UInt8] {
        // Padding-less base64: добиваем '=' и декодируем последний кусок.
        guard !quartet.isEmpty else { return [] }
        while quartet.count < 4 { quartet.append(UInt8(ascii: "=")) }
        let out = Self.decodeQuartet(quartet) ?? []
        quartet.removeAll()
        finished = true
        return out
    }

    private static func decodeQuartet(_ q: [UInt8]) -> [UInt8]? {
        guard q.count == 4 else { return nil }
        var vals: [UInt8] = []
        var pad = 0
        for b in q {
            if b == UInt8(ascii: "=") { pad += 1; vals.append(0); continue }
            guard let v = b64Value(b) else { return nil }
            vals.append(v)
        }
        let triple = (UInt32(vals[0]) << 18) | (UInt32(vals[1]) << 12)
                   | (UInt32(vals[2]) << 6) | UInt32(vals[3])
        var out: [UInt8] = []
        out.append(UInt8((triple >> 16) & 0xFF))
        if pad < 2 { out.append(UInt8((triple >> 8) & 0xFF)) }
        if pad < 1 { out.append(UInt8(triple & 0xFF)) }
        return out
    }

    private static func b64Value(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return c - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return c - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }
}

/// Фабрика по имени Content-Transfer-Encoding.
public enum MIMETransferEncoding: Sendable {
    public static func decoder(for encoding: String?) -> any MIMEStreamingDecoder {
        switch (encoding ?? "7bit").lowercased() {
        case "quoted-printable": return MIMEQuotedPrintableDecoder()
        case "base64": return MIMEBase64Decoder()
        default: return MIMEIdentityDecoder()
        }
    }
}
