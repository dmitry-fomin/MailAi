#if canImport(XCTest)
import XCTest
import Foundation
import Core
@testable import AI

final class ClassifyV1Tests: XCTestCase {

    func testSystemContainsJSONInstruction() {
        let input = Self.makeInput(rules: [])
        let prompt = ClassifyV1.build(input: input)
        XCTAssertTrue(prompt.system.contains("JSON"))
        XCTAssertTrue(prompt.system.contains("important"))
        XCTAssertTrue(prompt.system.contains("unimportant"))
    }

    func testUserContainsAllFields() {
        let input = Self.makeInput(rules: [])
        let prompt = ClassifyV1.build(input: input)
        XCTAssertTrue(prompt.user.contains("From: a@b.example"))
        XCTAssertTrue(prompt.user.contains("Subject: Привет"))
        XCTAssertTrue(prompt.user.contains("List-Unsubscribe: no"))
        XCTAssertTrue(prompt.user.contains("Snippet (150 chars):"))
    }

    func testListUnsubscribeFlag() {
        let input = Self.makeInput(rules: [], listUnsubscribe: true)
        let prompt = ClassifyV1.build(input: input)
        XCTAssertTrue(prompt.user.contains("List-Unsubscribe: yes"))
    }

    func testEmptyRulesBlock() {
        let input = Self.makeInput(rules: [])
        let prompt = ClassifyV1.build(input: input)
        XCTAssertTrue(prompt.system.contains("(нет)"))
    }

    func testWithRules() {
        let rules = [
            Rule(text: "от boss@me.com важное", intent: .markImportant, source: .manual),
            Rule(text: "от no-reply@x.com неважное", intent: .markUnimportant, source: .manual)
        ]
        let input = Self.makeInput(rules: rules)
        let prompt = ClassifyV1.build(input: input)
        XCTAssertTrue(prompt.system.contains("от boss@me.com важное → important"))
        XCTAssertTrue(prompt.system.contains("от no-reply@x.com неважное → unimportant"))
    }

    func testRulesCappedAt20() {
        let rules = (0..<30).map {
            Rule(text: "rule \($0)", intent: .markImportant, source: .manual)
        }
        let input = Self.makeInput(rules: rules)
        let prompt = ClassifyV1.build(input: input)
        let ruleLines = prompt.system
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("- rule ") }
        XCTAssertEqual(ruleLines.count, ClassifyV1.maxRules)
    }

    // MARK: - Helpers

    private static func makeInput(
        rules: [Rule],
        listUnsubscribe: Bool = false
    ) -> ClassificationInput {
        ClassificationInput(
            from: "a@b.example",
            to: ["me@example.com"],
            subject: "Привет",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            listUnsubscribe: listUnsubscribe,
            contentType: "text/plain",
            bodySnippet: String(repeating: "x", count: 150),
            activeRules: rules
        )
    }
}
#endif
