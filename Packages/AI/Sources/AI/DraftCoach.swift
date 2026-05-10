import Foundation
import Core

/// AI-коуч для черновиков писем.
///
/// Анализирует черновик письма перед отправкой и выдаёт список замечаний:
/// незакрытые вопросы, агрессивный тон, незавершённые мысли, грамматика.
///
/// ## Приватность
/// - Черновик и цитата оригинала передаются в AI только в памяти.
/// - Результат НЕ кешируется (каждый черновик уникален).
/// - Тела писем на диск не пишутся (инвариант CLAUDE.md).
///
/// ## Использование
/// ```swift
/// let coach = DraftCoach(provider: openRouterClient)
/// let review = try await coach.review(
///     subject: "Re: Budget Q2",
///     draftBody: "Sure, sounds fine.",
///     originalBody: "Could you send the report by Friday and confirm the budget?"
/// )
/// if !review.isClean {
///     // Показываем замечания пользователю
/// }
/// ```
public actor DraftCoach: AIDraftCoach {

    // MARK: - Dependencies

    private let provider: any AIProvider
    private var cachedSystemPrompt: String?

    // MARK: - Configuration

    /// Максимальная длина черновика, отправляемого в AI.
    private let maxDraftLength = 2_000
    /// Максимальная длина цитаты оригинала.
    private let maxOriginalLength = 500

    // MARK: - Init

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    // MARK: - AIDraftCoach

    /// Анализирует черновик письма и возвращает список замечаний.
    ///
    /// - Parameters:
    ///   - subject:      Тема письма.
    ///   - draftBody:    Текст черновика (только в памяти, не пишется на диск).
    ///   - originalBody: Цитата оригинала для reply/forward (опционально).
    /// - Returns: `DraftReview` — список замечаний или пустой (черновик ОК).
    public func review(
        subject: String,
        draftBody: String,
        originalBody: String? = nil
    ) async throws -> DraftReview {
        let draft    = String(draftBody.prefix(maxDraftLength))
        let original = originalBody.map { String($0.prefix(maxOriginalLength)) }

        let system = try await resolveSystemPrompt()
        let user   = buildUserMessage(
            subject: subject,
            draft: draft,
            original: original
        )

        var responseText = ""
        for try await chunk in provider.complete(
            system: system,
            user: user,
            streaming: false,
            maxTokens: 600
        ) {
            responseText += chunk
        }

        return parseResponse(responseText)
    }

    // MARK: - Private: Prompt

    private func resolveSystemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }
        let prompt = try await PromptStore.shared.load(id: "draft_coach")
        cachedSystemPrompt = prompt
        return prompt
    }

    private func buildUserMessage(
        subject: String,
        draft: String,
        original: String?
    ) -> String {
        var parts: [String] = []
        parts.append("Subject: \(subject)")
        parts.append("\nDraft:\n\(draft)")
        if let original, !original.isEmpty {
            parts.append("\nOriginal message (for context):\n\(original)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Private: Response parsing

    private func parseResponse(_ text: String) -> DraftReview {
        guard let start = text.firstIndex(of: "{"),
              let end   = text.lastIndex(of: "}"),
              start <= end,
              let data = String(text[start...end]).data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawIssues = dict["issues"] as? [[String: Any]]
        else {
            return DraftReview()
        }

        let issues = rawIssues.compactMap { Self.decodeDraftIssue($0) }
        return DraftReview(issues: issues)
    }

    private static func decodeDraftIssue(_ dict: [String: Any]) -> DraftIssue? {
        guard let kindRaw = dict["kind"] as? String,
              let kind    = DraftIssueKind(rawValue: kindRaw),
              let desc    = dict["description"] as? String
        else { return nil }

        let severityRaw = dict["severity"] as? String ?? "medium"
        let severity    = DraftIssueSeverity(rawValue: severityRaw) ?? .medium

        return DraftIssue(kind: kind, description: desc, severity: severity)
    }
}
