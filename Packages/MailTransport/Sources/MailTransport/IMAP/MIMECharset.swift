import Foundation

/// Определение строковой кодировки по имени charset из MIME Content-Type.
/// Используется стриминговым MIME-парсером для декодирования текстовых частей.
///
/// Политика: если charset неизвестен или декодирование не удалось — fallback
/// на UTF-8 (lossy-декодирование не применяется; потребитель получит nil и
/// сможет вывести байты сырыми).
public enum MIMECharset: Sendable {
    /// Возвращает `String.Encoding` по имени charset. Поддерживает популярные
    /// алиасы (utf-8, us-ascii, iso-8859-*, windows-125*, koi8-r, cp1251 и т.п.)
    /// через IANA-таблицу CoreFoundation. При неизвестном имени — `.utf8`.
    public static func encoding(for charset: String?) -> String.Encoding {
        guard let charset, !charset.isEmpty else { return .utf8 }
        let normalized = charset.lowercased()
        switch normalized {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "iso-8859-2", "latin2", "latin-2": return .isoLatin2
        case "windows-1251", "cp1251", "cp-1251": return .windowsCP1251
        case "windows-1252", "cp1252", "cp-1252": return .windowsCP1252
        case "windows-1253", "cp1253": return .windowsCP1253
        case "windows-1254", "cp1254": return .windowsCP1254
        case "koi8-r", "koi8r": return .init(rawValue: 0x0A02_0002) // NSKOI8RStringEncoding
        case "utf-16", "utf16": return .utf16
        case "utf-16be": return .utf16BigEndian
        case "utf-16le": return .utf16LittleEndian
        default:
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
            if cfEnc != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(cfEnc)
                return String.Encoding(rawValue: ns)
            }
            return .utf8
        }
    }

    /// Декодирует байты в строку с указанным charset; при ошибке — UTF-8 fallback;
    /// при повторной ошибке — nil.
    public static func decode(_ bytes: [UInt8], charset: String?) -> String? {
        let primary = encoding(for: charset)
        let data = Data(bytes)
        if let s = String(data: data, encoding: primary) { return s }
        if primary != .utf8, let s = String(data: data, encoding: .utf8) { return s }
        return nil
    }
}
