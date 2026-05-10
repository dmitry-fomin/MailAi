import Foundation

/// Метаданные одного AI-промпта для UI и `PromptStore.initializeDefaults()`.
/// `id` совпадает с именем `.md`-файла без расширения.
public struct PromptEntry: Identifiable, Sendable {
    public let id: String
    public let icon: String
    public let displayName: String
    public var content: String
    public var isCustom: Bool

    public init(id: String, icon: String, displayName: String, content: String = "", isCustom: Bool = false) {
        self.id = id
        self.icon = icon
        self.displayName = displayName
        self.content = content
        self.isCustom = isCustom
    }
}

public extension PromptEntry {
    static let allEntries: [PromptEntry] = [
        PromptEntry(id: "classify", icon: "sparkles", displayName: "Классификация"),
        PromptEntry(id: "summarize", icon: "text.quote", displayName: "Суммаризация"),
        PromptEntry(id: "extract_actions", icon: "checklist", displayName: "Действия"),
        PromptEntry(id: "quick_reply", icon: "arrowshape.turn.up.left", displayName: "Быстрый ответ"),
        PromptEntry(id: "bulk_delete", icon: "trash.fill", displayName: "Массовое удаление"),
        PromptEntry(id: "translate", icon: "character.bubble", displayName: "Перевод"),
        PromptEntry(id: "categorize", icon: "tag", displayName: "Категории"),
        PromptEntry(id: "snooze", icon: "clock.arrow.circlepath", displayName: "Snooze"),
        PromptEntry(id: "snippet", icon: "eye", displayName: "AI-сниппет"),
        PromptEntry(id: "draft_coach", icon: "pencil.and.outline", displayName: "Draft Coach"),
        PromptEntry(id: "nl_search", icon: "magnifyingglass", displayName: "NL-поиск"),
        PromptEntry(id: "follow_up", icon: "bell", displayName: "Follow-up"),
        PromptEntry(id: "attachment_summary", icon: "paperclip", displayName: "Вложения"),
        PromptEntry(id: "meeting_parser", icon: "calendar", displayName: "Встречи")
    ]
}
