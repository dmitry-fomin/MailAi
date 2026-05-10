#if canImport(XCTest)
import XCTest
import Foundation
import Core
@testable import AI

/// Простая in-memory реализация `AIProvider` для юнит-тестов.
struct StubAIProvider: AIProvider {
    let payloads: [String]

    init(_ payload: String) { self.payloads = [payload] }
    init(_ payloads: [String]) { self.payloads = payloads }

    func complete(
        system: String,
        user: String,
        streaming: Bool,
        maxTokens: Int = 200
    ) -> AsyncThrowingStream<String, any Error> {
        let copy = payloads
        return AsyncThrowingStream { continuation in
            for p in copy { continuation.yield(p) }
            continuation.finish()
        }
    }
}

final class ClassifierTests: XCTestCase {

    private func makeInput() -> ClassificationInput {
        ClassificationInput(
            from: "sender@example.com",
            to: ["me@example.com"],
            subject: "test",
            date: Date(),
            listUnsubscribe: false,
            contentType: "text/plain",
            bodySnippet: String(repeating: "x", count: 150),
            activeRules: []
        )
    }

    func testParsesCleanImportantJSON() async throws {
        let provider = StubAIProvider(#"{"importance":"important","confidence":0.92,"reasoning":"от живого человека"}"#)
        let classifier = Classifier(provider: provider, model: "test/model")
        let result = try await classifier.classify(input: makeInput())
        XCTAssertEqual(result.importance, .important)
        XCTAssertEqual(result.confidence, 0.92, accuracy: 1e-6)
        XCTAssertEqual(result.reasoning, "от живого человека")
        XCTAssertGreaterThan(result.tokensIn, 0)
        XCTAssertGreaterThanOrEqual(result.durationMs, 0)
    }

    func testParsesUnimportant() async throws {
        let provider = StubAIProvider(#"{"importance":"unimportant","confidence":0.7,"reasoning":"рассылка"}"#)
        let classifier = Classifier(provider: provider, model: "test/model")
        let result = try await classifier.classify(input: makeInput())
        XCTAssertEqual(result.importance, .unimportant)
    }

    func testExtractsJSONFromSurroundingText() async throws {
        let payload = """
            Here is my answer:
            ```json
            {"importance":"important","confidence":0.8,"reasoning":"важно"}
            ```
            Thanks!
            """
        let provider = StubAIProvider(payload)
        let classifier = Classifier(provider: provider, model: "test/model")
        let result = try await classifier.classify(input: makeInput())
        XCTAssertEqual(result.importance, .important)
    }

    func testThrowsOnEmptyResponse() async {
        let provider = StubAIProvider("")
        let classifier = Classifier(provider: provider, model: "test/model")
        do {
            _ = try await classifier.classify(input: makeInput())
            XCTFail("Expected empty response error")
        } catch let error as ClassifierError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testThrowsOnMalformedJSON() async {
        let provider = StubAIProvider("not a json at all")
        let classifier = Classifier(provider: provider, model: "test/model")
        do {
            _ = try await classifier.classify(input: makeInput())
            XCTFail("Expected malformed JSON error")
        } catch let error as ClassifierError {
            if case .malformedJSON = error {} else {
                XCTFail("Wrong case: \(error)")
            }
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testAccumulatesStreamingChunks() async throws {
        let chunks = [
            #"{"importance":"#,
            #""unimportant","confidence":"#,
            #"0.5,"reasoning":"test"}"#
        ]
        let provider = StubAIProvider(chunks)
        let classifier = Classifier(provider: provider, model: "test/model")
        let result = try await classifier.classify(input: makeInput())
        XCTAssertEqual(result.importance, .unimportant)
        XCTAssertEqual(result.confidence, 0.5)
    }
}
#endif
