import Foundation
import Core

/// Промпт классификации v1. Строит пару (system, user) из `ClassificationInput`.
/// System содержит инструкцию + список активных правил пользователя (топ-20).
/// User — структурированные поля письма + 150-char snippet.
public enum ClassifyV1 {
    public struct Prompt: Sendable, Equatable {
        public let system: String
        public let user: String
    }

    private static let systemBase = """
        Ты — AI-классификатор почты. Отвечай строго в JSON:
        {"importance":"important"|"unimportant","confidence":0.0-1.0,"reasoning":"одно короткое предложение"}

        Критерии:
        - "important": рабочие письма от людей, счета, приглашения на встречи, ответы в тредах, уведомления безопасности.
        - "unimportant": маркетинг, рассылки, автоматические уведомления сервисов, дайджесты.

        Правила пользователя (применяй в первую очередь, если применимы):
        """

    public static let maxRules = 20

    public static func build(input: ClassificationInput) -> Prompt {
        let rules = Array(input.activeRules.prefix(maxRules))
        let rulesBlock: String
        if rules.isEmpty {
            rulesBlock = "(нет)"
        } else {
            rulesBlock = rules
                .map { "- \($0.text) → \($0.intent == .markImportant ? "important" : "unimportant")" }
                .joined(separator: "\n")
        }

        let system = "\(systemBase)\n\(rulesBlock)"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let user = """
            From: \(input.from)
            To: \(input.to.joined(separator: ", "))
            Subject: \(input.subject)
            Date: \(iso.string(from: input.date))
            List-Unsubscribe: \(input.listUnsubscribe ? "yes" : "no")
            Content-Type: \(input.contentType)

            Snippet (150 chars): \(input.bodySnippet)
            """

        return Prompt(system: system, user: user)
    }
}
