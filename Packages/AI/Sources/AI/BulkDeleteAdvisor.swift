import Foundation
import Core

// MARK: - Public Types

/// Минимальный набор метаданных письма для анализа bulk-delete.
/// Тело письма не передаётся — только заголовки (privacy-invariant).
public struct MessageEnvelope: Sendable, Equatable {
    public let messageID: Message.ID
    public let from: String
    public let subject: String
    public let date: Date
    public let importance: Importance
    /// Наличие заголовка List-Unsubscribe — признак рассылки.
    public let isNewsletter: Bool

    public init(
        messageID: Message.ID,
        from: String,
        subject: String,
        date: Date,
        importance: Importance,
        isNewsletter: Bool = false
    ) {
        self.messageID = messageID
        self.from = from
        self.subject = subject
        self.date = date
        self.importance = importance
        self.isNewsletter = isNewsletter
    }
}

/// Кандидат на удаление, рекомендованный AI.
public struct BulkCandidate: Sendable, Equatable, Identifiable {
    public let id: Message.ID
    public let from: String
    public let subject: String
    public let date: Date
    /// Объяснение, почему письмо рекомендовано к удалению.
    public let reasoning: String

    public init(id: Message.ID, from: String, subject: String, date: Date, reasoning: String) {
        self.id = id
        self.from = from
        self.subject = subject
        self.date = date
        self.reasoning = reasoning
    }
}

/// Результат анализа: план массового удаления.
public struct BulkActionPlan: Sendable, Equatable {
    public let query: String
    public let candidates: [BulkCandidate]
    /// Общее объяснение принятых решений.
    public let overallReasoning: String

    public var count: Int { candidates.count }

    public init(query: String, candidates: [BulkCandidate], overallReasoning: String) {
        self.query = query
        self.candidates = candidates
        self.overallReasoning = overallReasoning
    }
}

// MARK: - Protocol

/// Абстракция советника по массовому удалению. Позволяет мокировать в тестах.
public protocol AIBulkAdvisor: Actor {
    /// Анализирует метаданные писем и возвращает план удаления.
    /// - Parameters:
    ///   - envelopes: Метаданные писем (только заголовки, не тела).
    ///   - query: Запрос пользователя, например "Delete all newsletters from last 6 months".
    func analyzeDeletion(
        envelopes: [MessageEnvelope],
        query: String
    ) async throws -> BulkActionPlan
}

// MARK: - Implementation

/// Актор-советник по массовому удалению писем.
///
/// Принимает массив `MessageEnvelope` (только метаданные, без тел),
/// анализирует через OpenRouter батчами по `batchSize` писем,
/// возвращает `BulkActionPlan` с кандидатами на удаление.
///
/// Двухшаговый флоу: AI предлагает → пользователь подтверждает.
/// Удаления без подтверждения пользователя не происходит.
public actor BulkDeleteAdvisor: AIBulkAdvisor {
    public let provider: any AIProvider
    public let model: String
    /// Максимальное количество писем в одном батче (ограничение контекста).
    public let batchSize: Int

    public init(provider: any AIProvider, model: String, batchSize: Int = 50) {
        self.provider = provider
        self.model = model
        self.batchSize = batchSize
    }

    public func analyzeDeletion(
        envelopes: [MessageEnvelope],
        query: String
    ) async throws -> BulkActionPlan {
        guard !envelopes.isEmpty else {
            return BulkActionPlan(query: query, candidates: [], overallReasoning: "No messages to analyze.")
        }

        // Разбиваем на батчи, анализируем каждый, объединяем результаты
        let batches = stride(from: 0, to: envelopes.count, by: batchSize).map { start in
            Array(envelopes[start..<min(start + batchSize, envelopes.count)])
        }

        var allCandidates: [BulkCandidate] = []
        var batchReasonings: [String] = []

        for batch in batches {
            let batchPlan = try await analyzeBatch(envelopes: batch, query: query)
            allCandidates.append(contentsOf: batchPlan.candidates)
            if !batchPlan.overallReasoning.isEmpty {
                batchReasonings.append(batchPlan.overallReasoning)
            }
        }

        let overallReasoning = batchReasonings.isEmpty
            ? "No messages recommended for deletion."
            : batchReasonings.joined(separator: " ")

        return BulkActionPlan(
            query: query,
            candidates: allCandidates,
            overallReasoning: overallReasoning
        )
    }

    // MARK: - Private

    private func analyzeBatch(envelopes: [MessageEnvelope], query: String) async throws -> BulkActionPlan {
        let system = Self.systemPrompt
        let user = buildUserPrompt(envelopes: envelopes, query: query)

        var buffer = ""
        for try await chunk in provider.complete(
            system: system,
            user: user,
            streaming: false,
            maxTokens: 800
        ) {
            buffer += chunk
        }

        guard !buffer.isEmpty else {
            return BulkActionPlan(query: query, candidates: [], overallReasoning: "")
        }

        return try parsePlan(buffer, envelopes: envelopes, query: query)
    }

    private func buildUserPrompt(envelopes: [MessageEnvelope], query: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let messagesList = envelopes.enumerated().map { idx, env in
            let newsletterMark = env.isNewsletter ? " [newsletter]" : ""
            let importanceMark = env.importance == .important ? " [important]" : ""
            return """
                \(idx + 1). ID:\(env.messageID.rawValue) | From:\(env.from) | Subject:\(env.subject)\(newsletterMark)\(importanceMark) | Date:\(iso.string(from: env.date))
                """
        }.joined(separator: "\n")

        return """
            User query: \(query)

            Messages to analyze (\(envelopes.count) total):
            \(messagesList)
            """
    }

    /// Парсит JSON-ответ модели. Если JSON не распознан — возвращает пустой план.
    private func parsePlan(
        _ text: String,
        envelopes: [MessageEnvelope],
        query: String
    ) throws -> BulkActionPlan {
        let json = Classifier.extractJSONObject(text)
        guard let data = json.data(using: .utf8),
              let root = try? JSONDecoder().decode(BulkDeleteResponse.self, from: data)
        else {
            return BulkActionPlan(query: query, candidates: [], overallReasoning: text)
        }

        // Строим словарь envelope по rawValue ID для быстрого поиска
        let envelopeByID = Dictionary(
            uniqueKeysWithValues: envelopes.map { ($0.messageID.rawValue, $0) }
        )

        let candidates = root.delete.compactMap { item -> BulkCandidate? in
            guard let env = envelopeByID[item.id] else { return nil }
            return BulkCandidate(
                id: env.messageID,
                from: env.from,
                subject: env.subject,
                date: env.date,
                reasoning: item.reason
            )
        }

        return BulkActionPlan(
            query: query,
            candidates: candidates,
            overallReasoning: root.summary
        )
    }

    // MARK: - Wire Types

    private struct BulkDeleteResponse: Decodable {
        let delete: [DeleteItem]
        let summary: String

        struct DeleteItem: Decodable {
            let id: String
            let reason: String
        }
    }

    // MARK: - System Prompt

    private static let systemPrompt = """
        You are an email cleanup advisor. Analyze message metadata and identify which emails can be safely deleted based on the user's query.

        IMPORTANT rules:
        - NEVER mark as delete: emails tagged [important], emails awaiting response from real people, receipts, contracts, security alerts.
        - SAFE to delete: marketing emails, newsletters [newsletter], automated notifications, unread digests older than 30 days, resolved threads.
        - Only include messages you are confident should be deleted.

        Respond strictly in JSON:
        {
          "delete": [
            {"id": "<message ID>", "reason": "<short explanation in user's language>"},
            ...
          ],
          "summary": "<1-2 sentence overall explanation>"
        }

        If no messages should be deleted, return {"delete": [], "summary": "No messages match the deletion criteria."}.
        """
}
