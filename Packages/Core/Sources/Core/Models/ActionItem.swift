import Foundation

/// Тип действия, извлечённого AI из письма.
public enum ActionKind: String, Sendable, Equatable, Codable, CaseIterable {
    case deadline
    case task
    case meeting
    case link
    case question
}

/// Одно действие, извлечённое из письма. Живёт только в памяти / ai_cache.
public struct ActionItem: Sendable, Identifiable, Equatable, Codable {
    public let id: String
    public let kind: ActionKind
    /// Текст действия: дедлайн, задача, ссылка и т.д.
    public let text: String
    /// Дата/срок, если удалось распознать (для kind == .deadline, .meeting).
    public let dueDate: Date?
    /// Локальный флаг «выполнено» — хранится только в памяти (@State).
    public var isCompleted: Bool

    public init(
        id: String,
        kind: ActionKind,
        text: String,
        dueDate: Date? = nil,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.dueDate = dueDate
        self.isCompleted = isCompleted
    }
}
