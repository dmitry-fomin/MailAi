import Foundation

/// Генератор тегов IMAP-команд. IMAP требует, чтобы каждая команда клиента
/// начиналась с уникального тега (например, `a001`), и сервер использовал
/// тот же тег в финальном ответе (tagged response).
///
/// Actor — для безопасной инкрементации из конкурентных задач.
public actor IMAPTagGenerator {
    private var counter: UInt64 = 0

    public init(start: UInt64 = 0) { self.counter = start }

    public func next() -> String {
        counter += 1
        return String(format: "a%04llu", counter)
    }
}
