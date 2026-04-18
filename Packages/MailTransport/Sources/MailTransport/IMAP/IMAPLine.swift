import Foundation
import NIOCore

/// Обёртка над строкой IMAP (без CRLF).
/// IMAP-линии терминируются `\r\n`; наш декодер снимает этот трейлер и
/// кодер добавляет его назад.
public struct IMAPLine: Sendable, Hashable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var description: String { raw }

    /// Для логирования: маскирует длинные куски (пароли и т.п.), оставляя
    /// первые и последние 4 символа слов длиннее 20.
    public var masked: String {
        raw.split(separator: " ").map { word -> String in
            word.count > 20 ? "\(word.prefix(4))…\(word.suffix(4))" : String(word)
        }.joined(separator: " ")
    }
}
