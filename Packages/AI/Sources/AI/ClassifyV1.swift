import Foundation
import Core

/// Промпт классификации v1. Строит пару (system, user) из `ClassificationInput`.
/// System содержит инструкцию + список активных правил пользователя (топ-20).
/// User — структурированные поля письма + 150-char snippet.
///
/// Расширенный ответ (v1.1): AI возвращает importance, category, language, tone
/// в одном JSON-объекте (~20 дополнительных токенов).
public enum ClassifyV1 {
    public struct Prompt: Sendable, Equatable {
        public let system: String
        public let user: String
    }

    private static let systemBase = """
        Ты — AI-классификатор почты. Отвечай строго в JSON:
        {
          "importance": "important" | "unimportant",
          "confidence": 0.0-1.0,
          "reasoning": "одно короткое предложение",
          "category": "work" | "finance" | "travel" | "social" | "legal" | "receipt" | "notification" | "personal" | "marketing" | "other",
          "language": "<ISO 639-1 код, например en, ru, de>",
          "tone": "positive" | "neutral" | "negative" | "urgent"
        }

        Критерии importance:
        - "important": рабочие письма от людей, счета, приглашения на встречи, ответы в тредах, уведомления безопасности.
        - "unimportant": маркетинг, рассылки, автоматические уведомления сервисов, дайджесты.

        Критерии category:
        - work: рабочая переписка, задачи, коллеги, клиенты.
        - finance: счета, платежи, банковские уведомления, налоги.
        - travel: авиабилеты, бронирования отелей, маршруты.
        - social: соцсети, мессенджеры, форумы.
        - legal: договоры, юридические уведомления.
        - receipt: чеки, подтверждения заказов.
        - notification: автоматические системные уведомления.
        - personal: личная переписка от знакомых.
        - marketing: рекламные рассылки, промоакции.
        - other: всё остальное.

        Критерии tone:
        - urgent: требует немедленной реакции, дедлайны, критические проблемы.
        - positive: хорошие новости, благодарности, поздравления.
        - negative: жалобы, отказы, проблемы.
        - neutral: обычная деловая/информационная переписка.

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
