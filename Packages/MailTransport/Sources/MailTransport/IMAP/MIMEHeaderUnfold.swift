import Foundation

/// RFC 5322 header unfolding и парсинг.
///
/// *Folding*: строка заголовка может быть разбита на несколько физических
/// линий, продолжающиеся строки начинаются с WSP (SPACE или HTAB).
/// *Unfolding*: CRLF перед WSP удаляется (WSP сохраняется).
///
/// Пример:
/// ```
/// Subject: a very
///  long subject
/// ```
/// → `Subject: a very long subject`
public enum MIMEHeaderUnfold: Sendable {
    /// Убирает CRLF (и одиночные LF) перед whitespace. Все прочие CRLF
    /// сохраняются как разделители заголовков.
    public static func unfold(_ raw: String) -> String {
        // Работаем на уровне UTF-8 байтов: Swift String склеивает "\r\n" в один
        // Character (grapheme cluster), поэтому посимвольный обход не годится.
        let bytes = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        let space = UInt8(ascii: " ")
        let tab = UInt8(ascii: "\t")
        let cr = UInt8(ascii: "\r")
        let lf = UInt8(ascii: "\n")
        while i < bytes.count {
            let b = bytes[i]
            if b == cr && i + 1 < bytes.count && bytes[i + 1] == lf
                && i + 2 < bytes.count && (bytes[i + 2] == space || bytes[i + 2] == tab) {
                i += 2  // пропускаем CRLF, WSP остаётся
                continue
            }
            if b == lf && i + 1 < bytes.count && (bytes[i + 1] == space || bytes[i + 1] == tab) {
                i += 1  // пропускаем LF, WSP остаётся
                continue
            }
            out.append(b)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Парсит блок заголовков (до пустой строки) в упорядоченный список пар
    /// `(name, value)`. `value` декодируется через RFC 2047. Имена заголовков
    /// возвращаются в исходном регистре; сравнение — регистронезависимое
    /// (помощник `find`).
    public static func parse(_ raw: String) -> [(name: String, value: String)] {
        let unfolded = unfold(raw)
        // Разделяем по LF через unicode scalars (String.split мешает grapheme
        // clusters для "\r\n").
        let scalars = Array(unfolded.unicodeScalars)
        var lines: [String] = []
        var current = ""
        for scalar in scalars {
            if scalar == "\n" {
                if current.hasSuffix("\r") { current.removeLast() }
                lines.append(current)
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(current) }

        var result: [(String, String)] = []
        for line in lines {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            result.append((name, IMAPHeaderDecoder.decode(value)))
        }
        return result
    }

    /// Находит первое значение заголовка по имени (регистронезависимо).
    public static func find(_ headers: [(name: String, value: String)], name: String) -> String? {
        let needle = name.lowercased()
        return headers.first { $0.name.lowercased() == needle }?.value
    }

    /// Парсит значение вида `text/plain; charset="utf-8"; boundary=xxx`
    /// в `(primary: "text/plain", params: ["charset": "utf-8", "boundary": "xxx"])`.
    public static func parseStructuredValue(_ value: String) -> (primary: String, params: [String: String]) {
        let segments = splitTopLevel(value, by: ";")
        guard !segments.isEmpty else { return ("", [:]) }
        let primary = segments[0].trimmingCharacters(in: .whitespaces).lowercased()
        var params: [String: String] = [:]
        for seg in segments.dropFirst() {
            let trimmed = seg.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return (primary, params)
    }

    /// Разделение по символу вне кавычек.
    private static func splitTopLevel(_ s: String, by sep: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == sep && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
