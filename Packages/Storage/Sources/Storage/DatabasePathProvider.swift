import Foundation

/// Вычисление путей к файлам БД. Один файл на аккаунт — изоляция окон
/// и скорость: одна БД не шарится между окнами.
public struct DatabasePathProvider: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// `~/Library/Application Support/MailAi/` по умолчанию.
    public static func `default`() throws -> DatabasePathProvider {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport.appendingPathComponent("MailAi", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return DatabasePathProvider(rootDirectory: root)
    }

    public func url(forAccountID accountID: String) -> URL {
        rootDirectory.appendingPathComponent("\(accountID).sqlite")
    }
}
