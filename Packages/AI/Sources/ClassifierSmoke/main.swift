import Foundation
import Core
import AI

/// Stub AIProvider: эмулирует ответ OpenRouter без сети.
struct StubProvider: AIProvider {
    let chunks: [String]
    init(_ payload: String) { self.chunks = [payload] }
    init(chunks: [String]) { self.chunks = chunks }

    func complete(
        system: String,
        user: String,
        streaming: Bool
    ) -> AsyncThrowingStream<String, any Error> {
        let copy = chunks
        return AsyncThrowingStream { continuation in
            for c in copy { continuation.yield(c) }
            continuation.finish()
        }
    }
}

@main
enum ClassifierSmoke {
    static func main() async throws {
        try await testImportant()
        try await testUnimportant()
        try await testJSONInFence()
        try await testStreamingChunks()
        try await testEmptyResponse()
        try await testMalformedJSON()
        try await testPromptContainsFields()
        print("✅ ClassifierSmoke: все проверки пройдены")
    }

    private static func makeInput(rules: [Rule] = []) -> ClassificationInput {
        ClassificationInput(
            from: "alice@example.com",
            to: ["me@example.com"],
            subject: "Hello",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            listUnsubscribe: false,
            contentType: "text/plain",
            bodySnippet: String(repeating: "x", count: 150),
            activeRules: rules
        )
    }

    private static func testImportant() async throws {
        let p = StubProvider(#"{"importance":"important","confidence":0.91,"reasoning":"от человека"}"#)
        let r = try await Classifier(provider: p, model: "stub").classify(input: makeInput())
        precondition(r.importance == .important, "expected important")
        precondition(abs(r.confidence - 0.91) < 1e-6, "confidence mismatch: \(r.confidence)")
        precondition(r.reasoning == "от человека", "reasoning mismatch")
        precondition(r.tokensIn > 0 && r.tokensOut > 0, "tokens must be > 0")
        precondition(r.durationMs >= 0, "duration must be >= 0")
    }

    private static func testUnimportant() async throws {
        let p = StubProvider(#"{"importance":"unimportant","confidence":0.6,"reasoning":"рассылка"}"#)
        let r = try await Classifier(provider: p, model: "stub").classify(input: makeInput())
        precondition(r.importance == .unimportant, "expected unimportant")
    }

    private static func testJSONInFence() async throws {
        let payload = """
            Here:
            ```json
            {"importance":"important","confidence":0.8,"reasoning":"ok"}
            ```
            """
        let r = try await Classifier(provider: StubProvider(payload), model: "stub")
            .classify(input: makeInput())
        precondition(r.importance == .important, "expected important from fenced JSON")
    }

    private static func testStreamingChunks() async throws {
        let chunks = [
            #"{"importance":"#,
            #""unimportant","confidence":"#,
            #"0.5,"reasoning":"x"}"#
        ]
        let r = try await Classifier(provider: StubProvider(chunks: chunks), model: "stub")
            .classify(input: makeInput())
        precondition(r.importance == .unimportant, "expected unimportant from streamed chunks")
        precondition(abs(r.confidence - 0.5) < 1e-6, "confidence mismatch")
    }

    private static func testEmptyResponse() async throws {
        do {
            _ = try await Classifier(provider: StubProvider(""), model: "stub")
                .classify(input: makeInput())
            fatalError("expected ClassifierError.emptyResponse")
        } catch ClassifierError.emptyResponse {
            // ok
        }
    }

    private static func testMalformedJSON() async throws {
        do {
            _ = try await Classifier(provider: StubProvider("not a json"), model: "stub")
                .classify(input: makeInput())
            fatalError("expected ClassifierError.malformedJSON")
        } catch ClassifierError.malformedJSON {
            // ok
        }
    }

    private static func testPromptContainsFields() async throws {
        let rule = Rule(
            text: "все от boss@example.com",
            intent: .markImportant,
            source: .manual
        )
        let input = makeInput(rules: [rule])
        let prompt = ClassifyV1.build(input: input)
        precondition(prompt.system.contains("AI-классификатор"),
                     "system prompt missing instructions: \(prompt.system)")
        precondition(prompt.system.contains(rule.text),
                     "system prompt must include active rules")
        precondition(prompt.user.contains("From: alice@example.com"),
                     "user prompt missing from field")
        precondition(prompt.user.contains("Subject: Hello"),
                     "user prompt missing subject")
        precondition(prompt.user.contains("List-Unsubscribe: no"),
                     "user prompt missing list-unsubscribe flag")
        precondition(prompt.user.contains(input.bodySnippet),
                     "user prompt missing body snippet")
    }
}
