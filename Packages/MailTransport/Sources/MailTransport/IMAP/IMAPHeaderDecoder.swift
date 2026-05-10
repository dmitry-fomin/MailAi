import Foundation

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
