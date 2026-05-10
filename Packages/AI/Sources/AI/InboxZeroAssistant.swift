import Foundation
import Core

// MARK: - Public Types

/// Группа писем в плане Inbox Zero.
public enum InboxZeroGroup: String, Sendable, Equatable, CaseIterable {
    /// Требуют ответа от пользователя.
    case needsReply
    /// Можно безопасно архивировать.
    case archive
    /// Рассылки — кандидаты на отписку.
    case newsletters
    /// Дубликаты или похожие письма.
    case duplicates
    /// Уже обработаны / устаревшие.
    case processed
}

/// Элемент плана для одного письма.
public struct InboxZeroItem: Sendable, Equatable, Identifiable {
    public let id: Message.ID
    public let from: String
    public let subject: String
    public let date: Date
    public let group: InboxZeroGroup
    /// Краткое пояснение AI.
    public let reasoning: String

    public init(
        id: Message.ID,
        from: String,
        subject: String,
        date: Date,
        group: InboxZeroGroup,
        reasoning: String
    ) {
        self.id = id
        self.from = from
        self.subject = subject
        self.date = date
        self.group = group
        self.reasoning = reasoning
    }
}

/// Полный план обработки входящих.
public struct InboxZeroPlan: Sendable, Equatable {
    /// Письма, разложенные по группам.
    public let items: [InboxZeroItem]
    /// Общее описание плана от AI.
    public let summary: String
    /// Общее число проанализированных писем.
    public let analyzedCount: Int

    public var needsReply: [InboxZeroItem] { items.filter { $0.group == .needsReply } }
    public var toArchive: [InboxZeroItem] { items.filter { $0.group == .archive } }
    public var newsletters: [InboxZeroItem] { items.filter { $0.group == .newsletters } }
    public var duplicates: [InboxZeroItem] { items.filter { $0.group == .duplicates } }
    public var processed: [InboxZeroItem] { items.filter { $0.group == .processed } }

    public init(items: [InboxZeroItem], summary: String, analyzedCount: Int) {
        self.items = items
        self.summary = summary
        self.analyzedCount = analyzedCount
    }
}

// MARK: - Protocol

/// Абстракция ассистента Inbox Zero. Принимает только метаданные писем.
public protocol AIInboxAdvisor: Actor {
    /// Анализирует список входящих и возвращает план обработки.
    /// - Parameter envelopes: Метаданные писем (не тела — только заголовки).
    func buildPlan(envelopes: [MessageEnvelope]) async throws -> InboxZeroPlan
}

// MARK: - Implementation

/// Актор-ассистент Inbox Zero.
///
/// Принимает до 500 метаданных писем (только заголовки), через OpenRouter
/// генерирует план: архивировать, ответить, отписаться, удалить дубликаты.
///
/// Стратегия батчинга: анализирует до `batchSize` писем за один запрос,
/// затем объединяет результаты. Тела писем не передаются (privacy-invariant).
///
/// Двухшаговый флоу: AI предлагает → пользователь подтверждает действия.
public actor InboxZeroAssistant: AIInboxAdvisor {
    public let provider: any AIProvider
    /// Максимальное число писем в одном AI-запросе.
    public let batchSize: Int
    /// Максимальное общее число писем для анализа.
    public static let maxMessages = 500

    public init(provider: any AIProvider, batchSize: Int = 60) {
        self.provider = provider
        self.batchSize = batchSize
    }

    public func buildPlan(envelopes: [MessageEnvelope]) async throws -> InboxZeroPlan {
        let capped = Array(envelopes.prefix(Self.maxMessages))
        guard !capped.isEmpty else {
            return InboxZeroPlan(
                items: [],
                summary: "Входящих писем нет.",
                analyzedCount: 0
            )
        }

        // Батчи — анализируем параллельно с ограниченной параллельностью
        let batches = stride(from: 0, to: capped.count, by: batchSize).map { start in
            Array(capped[start..<min(start + batchSize, capped.count)])
        }

        var allItems: [InboxZeroItem] = []

        // Последовательная обработка батчей — избегаем перегрузки OpenRouter
        for batch in batches {
            let batchItems = try await analyzeBatch(batch)
            allItems.append(contentsOf: batchItems)
        }

        // Финальный summary через AI (на основе статистики групп)
        let summary = buildSummary(items: allItems, totalAnalyzed: capped.count)

        return InboxZeroPlan(
            items: allItems,
            summary: summary,
            analyzedCount: capped.count
        )
    }

    // MARK: - Private

    private func analyzeBatch(_ envelopes: [MessageEnvelope]) async throws -> [InboxZeroItem] {
        let userPrompt = buildUserPrompt(envelopes: envelopes)

        var buffer = ""
        for try await chunk in provider.complete(
            system: Self.systemPrompt,
            user: userPrompt,
            streaming: false,
            maxTokens: 1200
        ) {
            buffer += chunk
        }

        guard !buffer.isEmpty else { return [] }
        return parseItems(buffer, envelopes: envelopes)
    }

    private func buildUserPrompt(envelopes: [MessageEnvelope]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let list = envelopes.enumerated().map { idx, env in
            var tags = ""
            if env.isNewsletter { tags += " [newsletter]" }
            if env.importance == .important { tags += " [important]" }
            return "\(idx + 1). ID:\(env.messageID.rawValue) | From:\(env.from) | Subject:\(env.subject)\(tags) | Date:\(iso.string(from: env.date))"
        }.joined(separator: "\n")

        return "Messages (\(envelopes.count)):\n\(list)"
    }

    /// Локальный summary без AI-запроса — считаем группы.
    private func buildSummary(items: [InboxZeroItem], totalAnalyzed: Int) -> String {
        let needsReply = items.filter { $0.group == .needsReply }.count
        let archive = items.filter { $0.group == .archive }.count
        let newsletters = items.filter { $0.group == .newsletters }.count
        let duplicates = items.filter { $0.group == .duplicates }.count

        var parts: [String] = []
        if needsReply > 0 { parts.append("\(needsReply) писем требуют ответа") }
        if archive > 0 { parts.append("\(archive) можно архивировать") }
        if newsletters > 0 { parts.append("\(newsletters) рассылок") }
        if duplicates > 0 { parts.append("\(duplicates) дубликатов") }

        let detail = parts.isEmpty ? "Входящие выглядят чистыми." : parts.joined(separator: ", ") + "."
        return "Проанализировано \(totalAnalyzed) писем. \(detail)"
    }

    private func parseItems(_ text: String, envelopes: [MessageEnvelope]) -> [InboxZeroItem] {
        let json = Classifier.extractJSONObject(text)
        guard let data = json.data(using: .utf8),
              let root = try? JSONDecoder().decode(InboxZeroResponse.self, from: data)
        else { return [] }

        let envelopeByID = Dictionary(
            uniqueKeysWithValues: envelopes.map { ($0.messageID.rawValue, $0) }
        )

        return root.plan.compactMap { item -> InboxZeroItem? in
            guard let env = envelopeByID[item.id] else { return nil }
            let group = InboxZeroGroup(rawValue: item.group) ?? .processed
            return InboxZeroItem(
                id: env.messageID,
                from: env.from,
                subject: env.subject,
                date: env.date,
                group: group,
                reasoning: item.reason
            )
        }
    }

    // MARK: - Wire Types

    private struct InboxZeroResponse: Decodable {
        let plan: [PlanItem]

        struct PlanItem: Decodable {
            let id: String
            let group: String
            let reason: String
        }
    }

    // MARK: - System Prompt

    private static let systemPrompt = """
        You are an Inbox Zero assistant. Analyze email metadata and classify each message into one of these groups:
        - "needsReply" — requires a response from the user (real person sent it, question/request present)
        - "archive" — safe to archive (read, resolved, informational)
        - "newsletters" — marketing or newsletter content (unsubscribe candidate)
        - "duplicates" — duplicate or very similar to another message in the list
        - "processed" — already handled, old, or otherwise done

        Rules:
        - Mark [important] messages as "needsReply" or "archive" ONLY — never "newsletters" or "duplicates".
        - [newsletter] tag strongly suggests "newsletters" group.
        - Be conservative: when in doubt, use "archive" not "needsReply".

        Respond strictly in JSON:
        {
          "plan": [
            {"id": "<message ID>", "group": "<group>", "reason": "<brief explanation in user's language>"},
            ...
          ]
        }

        Include ALL messages from the input in the plan.
        """
}
