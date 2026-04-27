import Foundation

/// Manages AI prompt files. User overrides stored in ~/.mailai/prompts/
/// Falls back to bundled defaults when no override exists.
public actor PromptStore {
    public static let shared = PromptStore()

    private let userPromptsDir: URL

    public init(userPromptsDir: URL = .defaultUserPromptsDir) {
        self.userPromptsDir = userPromptsDir
    }

    /// Loads user override if exists, otherwise returns bundled default.
    public func load(id: String) throws -> String {
        let userFile = userPromptsDir.appendingPathComponent("\(id).md")
        if FileManager.default.fileExists(atPath: userFile.path) {
            return try String(contentsOf: userFile, encoding: .utf8)
        }
        guard let url = Bundle.module.url(forResource: id, withExtension: "md", subdirectory: "Prompts") else {
            throw PromptStoreError.notFound(id)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Saves user override for the given prompt id.
    public func save(id: String, content: String) throws {
        try FileManager.default.createDirectory(
            at: userPromptsDir,
            withIntermediateDirectories: true
        )
        let file = userPromptsDir.appendingPathComponent("\(id).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Deletes user override, reverting to bundled default.
    public func reset(id: String) throws {
        let file = userPromptsDir.appendingPathComponent("\(id).md")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Returns true if a user override exists for the given prompt id.
    public func isCustom(id: String) -> Bool {
        let file = userPromptsDir.appendingPathComponent("\(id).md")
        return FileManager.default.fileExists(atPath: file.path)
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
