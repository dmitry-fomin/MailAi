#if canImport(XCTest)
import XCTest
import Foundation
@testable import AI

/// Интеграционный тест реального OpenRouter. Запускается только если в env
/// установлены `LLM_PROVIDER_API_KEY` (+ опционально `LLM_PROVIDER_API_BASE`).
/// Иначе skip. Ключ никогда не попадает в код/git.
final class OpenRouterIntegrationTests: XCTestCase {

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["LLM_PROVIDER_API_KEY"]
    }

    private var model: String {
        ProcessInfo.processInfo.environment["LLM_PROVIDER_MODEL"]
            ?? "google/gemini-2.5-flash-lite"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testLiveNonStreamingReturnsContent() async throws {
        try XCTSkipUnless(apiKey != nil, "LLM_PROVIDER_API_KEY not set — live test skipped")
        let client = OpenRouterClient(apiKey: apiKey!, model: model)
        var buffer = ""
        let started = Date()
        for try await chunk in client.complete(
            system: "You are a terse assistant. Reply in one word only.",
            user: "Say the word: pong",
            streaming: false
        ) {
            buffer += chunk
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(buffer.isEmpty, "Expected non-empty response")
        XCTAssertLessThan(elapsed, 30, "Live call should complete under 30s")
        print("[live non-stream] model=\(model) elapsed=\(String(format: "%.2f", elapsed))s chars=\(buffer.count)")
    }

    func testLiveStreamingEmitsMultipleChunks() async throws {
        try XCTSkipUnless(apiKey != nil, "LLM_PROVIDER_API_KEY not set — live test skipped")
        let client = OpenRouterClient(apiKey: apiKey!, model: model)
        var chunks: [String] = []
        let started = Date()
        for try await chunk in client.complete(
            system: "You are terse. Reply with exactly 5 short words.",
            user: "List 5 colors separated by spaces.",
            streaming: true
        ) {
            chunks.append(chunk)
        }
        let elapsed = Date().timeIntervalSince(started)
        let combined = chunks.joined()
        XCTAssertFalse(combined.isEmpty)
        XCTAssertLessThan(elapsed, 30)
        print("[live stream] model=\(model) chunks=\(chunks.count) elapsed=\(String(format: "%.2f", elapsed))s chars=\(combined.count)")
    }
}
#endif
