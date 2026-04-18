#if canImport(XCTest)
import XCTest
import Foundation
import Core
@testable import AI

/// End-to-end live тест: `Classifier` → `OpenRouterClient` → реальная модель.
/// Skip если не установлен `LLM_PROVIDER_API_KEY`.
final class ClassifierIntegrationTests: XCTestCase {

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["LLM_PROVIDER_API_KEY"]
    }

    private var model: String {
        ProcessInfo.processInfo.environment["LLM_PROVIDER_MODEL"]
            ?? "google/gemini-2.5-flash-lite"
    }

    func testClassifyMarketingEmailAsUnimportant() async throws {
        try XCTSkipUnless(apiKey != nil, "LLM_PROVIDER_API_KEY not set")
        let client = OpenRouterClient(apiKey: apiKey!, model: model)
        let classifier = Classifier(provider: client, model: model)

        let snippet = SnippetExtractor.extract(
            body: "🎉 Большая распродажа! Только сегодня скидки до 80% на всё. Успейте купить! Отписаться от рассылок можно по ссылке ниже.",
            contentType: "text/plain"
        )
        let input = ClassificationInput(
            from: "promo@shop.example",
            to: ["me@example.com"],
            subject: "🎉 Скидки до 80%!",
            date: Date(),
            listUnsubscribe: true,
            contentType: "text/plain",
            bodySnippet: snippet,
            activeRules: []
        )
        let result = try await classifier.classify(input: input)
        XCTAssertEqual(result.importance, .unimportant,
                       "Marketing email with unsubscribe header should be unimportant. Got reasoning: \(result.reasoning)")
        XCTAssertGreaterThan(result.confidence, 0.3)
        print("[live classify marketing] importance=\(result.importance) conf=\(result.confidence) ms=\(result.durationMs) reasoning=\(result.reasoning)")
    }

    func testClassifyWorkEmailAsImportant() async throws {
        try XCTSkipUnless(apiKey != nil, "LLM_PROVIDER_API_KEY not set")
        let client = OpenRouterClient(apiKey: apiKey!, model: model)
        let classifier = Classifier(provider: client, model: model)

        let snippet = SnippetExtractor.extract(
            body: "Привет, нужно обсудить сроки по проекту MailAi. Можешь созвониться завтра в 15:00? Я подготовил план релиза.",
            contentType: "text/plain"
        )
        let input = ClassificationInput(
            from: "colleague@company.example",
            to: ["me@example.com"],
            subject: "Обсудим сроки по проекту",
            date: Date(),
            listUnsubscribe: false,
            contentType: "text/plain",
            bodySnippet: snippet,
            activeRules: []
        )
        let result = try await classifier.classify(input: input)
        XCTAssertEqual(result.importance, .important,
                       "Personal work email should be important. Got reasoning: \(result.reasoning)")
        print("[live classify work] importance=\(result.importance) conf=\(result.confidence) ms=\(result.durationMs) reasoning=\(result.reasoning)")
    }

    func testUserRuleOverridesClassification() async throws {
        try XCTSkipUnless(apiKey != nil, "LLM_PROVIDER_API_KEY not set")
        let client = OpenRouterClient(apiKey: apiKey!, model: model)
        let classifier = Classifier(provider: client, model: model)

        // Обычный рабочий тред, но правило пользователя говорит "от colleague — неважное"
        let rule = Rule(
            text: "Письма от colleague@company.example всегда считать неважными",
            intent: .markUnimportant,
            source: .manual
        )
        let snippet = SnippetExtractor.extract(
            body: "Привет, когда встречаемся?",
            contentType: "text/plain"
        )
        let input = ClassificationInput(
            from: "colleague@company.example",
            to: ["me@example.com"],
            subject: "встреча",
            date: Date(),
            listUnsubscribe: false,
            contentType: "text/plain",
            bodySnippet: snippet,
            activeRules: [rule]
        )
        let result = try await classifier.classify(input: input)
        XCTAssertEqual(result.importance, .unimportant,
                       "User rule should override default classification. Got reasoning: \(result.reasoning)")
        print("[live classify rule-override] importance=\(result.importance) conf=\(result.confidence) reasoning=\(result.reasoning)")
    }
}
#endif
