import SwiftUI
import Core

// MARK: - MailKeyboardShortcuts

/// View-модификатор, добавляющий полный набор клавиатурных сокращений
/// как в Apple Mail.
///
/// Шорткаты реализованы через скрытые `Button` с `.keyboardShortcut`,
/// чтобы они работали вне зависимости от активного `FocusState`.
///
/// ## Полный набор
/// | Клавиша          | Действие                         |
/// |------------------|----------------------------------|
/// | R                | Ответить (Reply)                 |
/// | Shift+R          | Ответить всем (Reply All)        |
/// | F                | Переслать (Forward)              |
/// | E                | Архивировать (Archive)           |
/// | Delete           | Удалить (Delete)                 |
/// | Backspace        | Удалить (Delete)                 |
/// | Space            | Следующее непрочитанное          |
/// | N                | Новое письмо (Compose)           |
/// | Cmd+F            | Поиск (Search focus)             |
/// | Cmd+R            | Обновить (Refresh) — уже есть   |
/// | Cmd+1            | Фокус: Sidebar — уже есть        |
/// | Cmd+2            | Фокус: Список — уже есть         |
///
/// Использование:
/// ```swift
/// AccountWindowScene(session: session)
///     .mailKeyboardShortcuts(session: session, onReply: { … }, …)
/// ```
public struct MailKeyboardShortcutsModifier: ViewModifier {

    // MARK: - Callbacks

    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onNextUnread: () -> Void
    let onCompose: () -> Void
    let onFocusSearch: () -> Void

    // MARK: - Body

    public func body(content: Content) -> some View {
        content
            .background(shortcutButtons)
    }

    // MARK: - Shortcut buttons

    @ViewBuilder
    private var shortcutButtons: some View {
        ZStack {
            // R — ответить
            Button("Reply") { onReply() }
                .keyboardShortcut("r", modifiers: [])

            // Shift+R — ответить всем
            Button("Reply All") { onReplyAll() }
                .keyboardShortcut("r", modifiers: [.shift])

            // F — переслать
            Button("Forward") { onForward() }
                .keyboardShortcut("f", modifiers: [])

            // E — архивировать (как в Apple Mail)
            Button("Archive") { onArchive() }
                .keyboardShortcut("e", modifiers: [])

            // Delete — удалить
            Button("Delete") { onDelete() }
                .keyboardShortcut(.delete, modifiers: [])

            // Space — следующее непрочитанное
            Button("Next Unread") { onNextUnread() }
                .keyboardShortcut(" ", modifiers: [])

            // N — новое письмо
            Button("Compose") { onCompose() }
                .keyboardShortcut("n", modifiers: [])

            // Cmd+F — поиск
            Button("Search") { onFocusSearch() }
                .keyboardShortcut("f", modifiers: [.command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - View Extension

public extension View {
    /// Добавляет полный набор клавиатурных сокращений почтового клиента.
    ///
    /// - Parameters:
    ///   - onReply: Ответить на выбранное письмо (R).
    ///   - onReplyAll: Ответить всем (Shift+R).
    ///   - onForward: Переслать (F).
    ///   - onArchive: Архивировать (E).
    ///   - onDelete: Удалить (Delete / Backspace).
    ///   - onNextUnread: Перейти к следующему непрочитанному (Space).
    ///   - onCompose: Новое письмо (N).
    ///   - onFocusSearch: Фокус на строку поиска (Cmd+F).
    func mailKeyboardShortcuts(
        onReply: @escaping () -> Void,
        onReplyAll: @escaping () -> Void,
        onForward: @escaping () -> Void,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onNextUnread: @escaping () -> Void,
        onCompose: @escaping () -> Void,
        onFocusSearch: @escaping () -> Void
    ) -> some View {
        modifier(MailKeyboardShortcutsModifier(
            onReply: onReply,
            onReplyAll: onReplyAll,
            onForward: onForward,
            onArchive: onArchive,
            onDelete: onDelete,
            onNextUnread: onNextUnread,
            onCompose: onCompose,
            onFocusSearch: onFocusSearch
        ))
    }
}
