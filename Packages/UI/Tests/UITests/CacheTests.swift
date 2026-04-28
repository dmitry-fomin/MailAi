#if canImport(XCTest)
import XCTest
@testable import UI

final class MessageBodyCacheTests: XCTestCase {
    var cache: MessageBodyCache!
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        cache = MessageBodyCache(cacheDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testReadReturnNilForMiss() async throws {
        let result = await cache.read(messageID: "msg-001")
        XCTAssertNil(result)
    }

    func testWriteThenRead() async throws {
        let html = "<p>Hello world</p>"
        await cache.write(messageID: "msg-001", processedHTML: html)
        let result = await cache.read(messageID: "msg-001")
        XCTAssertEqual(result, html)
    }

    func testInvalidateRemovesEntry() async throws {
        await cache.write(messageID: "msg-001", processedHTML: "<p>test</p>")
        await cache.invalidate(messageID: "msg-001")
        let result = await cache.read(messageID: "msg-001")
        XCTAssertNil(result)
    }

    func testClearAllRemovesEverything() async throws {
        await cache.write(messageID: "msg-001", processedHTML: "<p>one</p>")
        await cache.write(messageID: "msg-002", processedHTML: "<p>two</p>")
        _ = await cache.clearAll()
        let r1 = await cache.read(messageID: "msg-001")
        let r2 = await cache.read(messageID: "msg-002")
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    func testClearAllReturnsByteCount() async throws {
        let html = "<p>Hello</p>"
        await cache.write(messageID: "msg-001", processedHTML: html)
        let freed = await cache.clearAll()
        XCTAssertGreaterThan(freed, 0)
    }

    func testTotalSizeReflectsWritten() async throws {
        let html = String(repeating: "x", count: 1000)
        await cache.write(messageID: "msg-001", processedHTML: html)
        let size = await cache.totalSize()
        XCTAssertGreaterThan(size, 500)
    }

    func testAllFilesReturnsCorrectMessageIDHash() async throws {
        await cache.write(messageID: "test-message-id", processedHTML: "<p>test</p>")
        let files = await cache.allFiles()
        XCTAssertEqual(files.count, 1)
        // messageIDHash должен совпадать с хешем из fileURL(for:)
        let expectedURL = await cache.fileURL(for: "test-message-id")
        let expectedHash = expectedURL.deletingPathExtension().lastPathComponent
        XCTAssertEqual(files[0].messageIDHash, expectedHash)
    }
}
final class AttachmentCacheStoreTests: XCTestCase {
    var store: AttachmentCacheStore!
    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = AttachmentCacheStore(cacheDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testReadReturnNilForMiss() async throws {
        let result = await store.read(messageID: "msg-1", contentID: "img001")
        XCTAssertNil(result)
    }

    func testWriteThenRead() async throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header
        await store.write(messageID: "msg-1", contentID: "img001", data: data, mimeType: "image/png")
        let result = await store.read(messageID: "msg-1", contentID: "img001")
        XCTAssertEqual(result?.0, data)
        XCTAssertEqual(result?.1, "image/png")
    }

    func testClearAllRemovesFiles() async throws {
        let data = Data([0x01, 0x02])
        await store.write(messageID: "msg-1", contentID: "img001", data: data, mimeType: "image/jpeg")
        _ = await store.clearAll()
        let result = await store.read(messageID: "msg-1", contentID: "img001")
        XCTAssertNil(result)
    }

    func testMessageIDHashStoredInMeta() async throws {
        let data = Data([0x01])
        await store.write(messageID: "msg-abc", contentID: "img001", data: data, mimeType: "image/png")
        let files = await store.allFiles()
        XCTAssertTrue(files.contains { $0.messageIDHash == AttachmentCacheStore.sha256("msg-abc") })
    }
}
#endif
