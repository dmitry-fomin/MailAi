import Foundation

/// Тип замечания к черновику письма.
public enum DraftIssueKind: String, Sendable, Codable, CaseIterable {
    /// Незакрытый вопрос из цитируемого треда.
    case unansweredQuestion
    /// Агрессивный или грубый тон.
    case aggressiveTone
    /// Незавершённая мысль или обрыв текста.
    case incompleteThought
    /// Отсутствует важный контекст.
    case missingContext
    /// Грамматическая ошибка.
    case grammarError
}

/// Уровень критичности замечания.
public enum DraftIssueSeverity: String, Sendable, Codable, CaseIterable, Comparable {
    case low
    case medium
    case high

    public static func < (lhs: DraftIssueSeverity, rhs: DraftIssueSeverity) -> Bool {
        let order: [DraftIssueSeverity] = [.low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// Одно замечание к черновику письма.
public struct DraftIssue: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Тип замечания.
    public let kind: DraftIssueKind
    /// Краткое описание проблемы (1–2 предложения).
    public let description: String
    /// Уровень критичности.
    public let severity: DraftIssueSeverity

    public init(
        id: UUID = UUID(),
        kind: DraftIssueKind,
        description: String,
        severity: DraftIssueSeverity
    ) {
        self.id = id
        self.kind = kind
        self.description = description
        self.severity = severity
    }
}

/// Результат проверки черновика.
public struct DraftReview: Sendable, Equatable {
    /// Список замечаний. Пустой — черновик выглядит хорошо.
    public let issues: [DraftIssue]

    public init(issues: [DraftIssue] = []) {
        self.issues = issues
    }

    /// `true` — нет замечаний.
    public var isClean: Bool { issues.isEmpty }

    /// Максимальная критичность среди всех замечаний.
    public var maxSeverity: DraftIssueSeverity? {
        issues.map(\.severity).max()
    }

    /// Замечания с уровнем `high`.
    public var criticalIssues: [DraftIssue] {
        issues.filter { $0.severity == .high }
    }
}

/// Протокол AI-коуча черновиков.
///
/// Анализирует черновик и возвращает список замечаний.
/// Тело письма передаётся только в памяти — на диск не записывается.
public protocol AIDraftCoach: Sendable {
    /// Проверяет черновик письма.
    ///
    /// - Parameters:
    ///   - subject:      Тема письма.
    ///   - draftBody:    Текст черновика (plain-text, только в памяти).
    ///   - originalBody: Цитата оригинального письма для reply/forward (опционально).
    ///                   Первые 500 символов. Передаётся только в памяти.
    /// - Returns: `DraftReview` со списком замечаний.
    func review(
        subject: String,
        draftBody: String,
        originalBody: String?
    ) async throws -> DraftReview
}
