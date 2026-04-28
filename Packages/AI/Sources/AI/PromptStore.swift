import Foundation

/// Manages AI prompt files. User overrides stored in ~/.mailai/prompts/
/// Falls back to bundled defaults when no override exists.
///
/// Все методы async — файловый I/O выполняется в detached-задаче с приоритетом
/// .utility, чтобы не блокировать кооперативный thread pool актора.
public actor PromptStore {
    public static let shared = PromptStore()

    private let userPromptsDir: URL

    public init(userPromptsDir: URL = .defaultUserPromptsDir) {
        self.userPromptsDir = userPromptsDir
    }

    /// Loads user override if exists, otherwise returns bundled default.
    public func load(id: String) async throws -> String {
        let dir = userPromptsDir
        return try await Task.detached(priority: .utility) {
            let userFile = dir.appendingPathComponent("\(id).md")
            if FileManager.default.fileExists(atPath: userFile.path) {
                return try String(contentsOf: userFile, encoding: .utf8)
            }
            guard let url = Bundle.module.url(forResource: id, withExtension: "md") else {
                throw PromptStoreError.notFound(id)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    /// Saves user override for the given prompt id.
    public func save(id: String, content: String) async throws {
        let dir = userPromptsDir
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let file = dir.appendingPathComponent("\(id).md")
            try content.write(to: file, atomically: true, encoding: .utf8)
        }.value
    }

    /// Copies all bundled prompts to userPromptsDir if they don't already exist.
    /// Safe to call multiple times — skips existing files.
    public func initializeDefaults() async throws {
        let dir = userPromptsDir
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            for entry in PromptEntry.allEntries {
                let dest = dir.appendingPathComponent("\(entry.id).md")
                guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
                guard let src = Bundle.module.url(
                    forResource: entry.id,
                    withExtension: "md"
                ) else {
                    throw PromptStoreError.notFound(entry.id)
                }
                try FileManager.default.copyItem(at: src, to: dest)
            }
        }.value
    }

    /// Restores the bundled default for the given prompt id, overwriting any user override.
    public func reset(id: String) async throws {
        let dir = userPromptsDir
        try await Task.detached(priority: .utility) {
            guard let src = Bundle.module.url(
                forResource: id,
                withExtension: "md"
            ) else {
                throw PromptStoreError.notFound(id)
            }
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let dest = dir.appendingPathComponent("\(id).md")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
        }.value
    }

    /// Returns true if a user override exists for the given prompt id.
    public func isCustom(id: String) async -> Bool {
        let dir = userPromptsDir
        return await Task.detached(priority: .utility) {
            let file = dir.appendingPathComponent("\(id).md")
            return FileManager.default.fileExists(atPath: file.path)
        }.value
    }
}

public enum PromptStoreError: Error, LocalizedError {
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Bundled prompt not found: \(id)"
        }
    }
}

public extension URL {
    static var defaultUserPromptsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mailai/prompts")
    }
}
