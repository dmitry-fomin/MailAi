#if canImport(XCTest)
import XCTest
@testable import AI

final class PromptStoreTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func testInitializeDefaultsCreatesAllFiles() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()

        for entry in PromptEntry.allEntries {
            let file = tmp.appendingPathComponent("\(entry.id).md")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "\(entry.id).md should exist after initializeDefaults"
            )
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(content.isEmpty, "\(entry.id).md should not be empty")
        }
    }

    func testInitializeDefaultsDoesNotOverwriteExistingFile() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let customContent = "custom user override"
        let file = tmp.appendingPathComponent("summarize.md")
        try customContent.write(to: file, atomically: true, encoding: .utf8)

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()

        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content, customContent,
            "initializeDefaults must not overwrite existing user file")
    }

    func testInitializeDefaultsIdempotent() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()
        try await store.initializeDefaults()

        let file = tmp.appendingPathComponent("summarize.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testResetRestoresBundleContent() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        try await store.initializeDefaults()

        let file = tmp.appendingPathComponent("summarize.md")
        let bundleContent = try String(contentsOf: file, encoding: .utf8)

        try "custom override".write(to: file, atomically: true, encoding: .utf8)
        try await store.reset(id: "summarize")

        let restored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(restored, bundleContent,
            "reset must restore bundled default content")
    }

    func testResetCreatesFileIfMissing() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PromptStore(userPromptsDir: tmp)
        try await store.reset(id: "summarize")

        let file = tmp.appendingPathComponent("summarize.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
