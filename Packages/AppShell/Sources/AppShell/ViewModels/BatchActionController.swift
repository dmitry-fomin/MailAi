import Foundation
import Core

/// Контроллер batch-операций над несколькими письмами.
///
/// Хранит набор выбранных идентификаторов и предоставляет методы для
/// массовых действий (прочитать/непрочитать, удалить, переместить,
/// архивировать). Изолирован на `@MainActor` — напрямую взаимодействует
/// с `AccountSessionModel` для обновления UI-состояния.
@MainActor
public final class BatchActionController: ObservableObject {

    // MARK: - Published state

    /// Набор выбранных идентификаторов писем.
    @Published public private(set) var selectedIDs: Set<Message.ID> = []

    /// `true`, пока выполняется batch-операция.
    @Published public private(set) var isProcessing: Bool = false

    /// Ошибка последней batch-операции.
    @Published public private(set) var lastError: MailError?

    // MARK: - Dependencies

    private weak var session: AccountSessionModel?

    // MARK: - Init

    public init(session: AccountSessionModel) {
        self.session = session
    }

    // MARK: - Selection API

    /// Заменяет выбор полным набором идентификаторов.
    public func setSelection(_ ids: Set<Message.ID>) {
        selectedIDs = ids
    }

    /// Добавляет / убирает один идентификатор из выбора (toggle).
    public func toggle(_ id: Message.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// Выбирает все переданные письма.
    public func selectAll(_ messages: [Message]) {
        selectedIDs = Set(messages.map(\.id))
    }

    /// Снимает весь выбор.
    public func clearSelection() {
        selectedIDs = []
    }

    public var hasSelection: Bool { !selectedIDs.isEmpty }

    public var selectionCount: Int { selectedIDs.count }

    // MARK: - Batch Actions

    /// Помечает все выбранные письма как прочитанные.
    public func markRead() async {
        await performBatch { actions, id in
            try await actions.setRead(true, messageID: id)
        } updateLocal: { [weak self] id in
            self?.session?.updateFlagsPublic(messageID: id) { $0.insert(.seen) }
        }
    }

    /// Помечает все выбранные письма как непрочитанные.
    public func markUnread() async {
        await performBatch { actions, id in
            try await actions.setRead(false, messageID: id)
        } updateLocal: { [weak self] id in
            self?.session?.updateFlagsPublic(messageID: id) { $0.remove(.seen) }
        }
    }

    /// Удаляет все выбранные письма.
    public func delete() async {
        let ids = selectedIDs
        await performBatch { actions, id in
            try await actions.delete(messageID: id)
        } updateLocal: { [weak self] id in
            self?.session?.removeFromListPublic(messageID: id)
        }
        // Снимаем выбор после успешного удаления
        let remaining = selectedIDs.intersection(ids)
        if remaining.isEmpty { clearSelection() }
    }

    /// Архивирует все выбранные письма.
    public func archive() async {
        let ids = selectedIDs
        await performBatch { actions, id in
            try await actions.archive(messageID: id)
        } updateLocal: { [weak self] id in
            self?.session?.removeFromListPublic(messageID: id)
        }
        let remaining = selectedIDs.intersection(ids)
        if remaining.isEmpty { clearSelection() }
    }

    /// Перемещает все выбранные письма в указанную папку.
    public func move(to targetMailboxID: Mailbox.ID) async {
        let ids = selectedIDs
        await performBatch { actions, id in
            try await actions.moveToMailbox(messageID: id, targetMailboxID: targetMailboxID)
        } updateLocal: { [weak self] id in
            self?.session?.removeFromListPublic(messageID: id)
        }
        let remaining = selectedIDs.intersection(ids)
        if remaining.isEmpty { clearSelection() }
    }

    /// Устанавливает флаг у всех выбранных писем.
    public func flag() async {
        await performBatch { actions, id in
            try await actions.setFlagged(true, messageID: id)
        } updateLocal: { [weak self] id in
            self?.session?.updateFlagsPublic(messageID: id) { $0.insert(.flagged) }
        }
    }

    /// Снимает флаг у всех выбранных писем.
    public func unflag() async {
        await performBatch { actions, id in
            try await actions.setFlagged(false, messageID: id)
        } updateLocal: { [weak self] id in
            self?.session?.updateFlagsPublic(messageID: id) { $0.remove(.flagged) }
        }
    }

    // MARK: - Private

    /// Выполняет действие над каждым выбранным письмом последовательно.
    /// Первая ошибка прерывает обход и сохраняется в `lastError`.
    /// Локальное обновление UI применяется только для успешно обработанных.
    private func performBatch(
        server: (any MailActionsProvider, Message.ID) async throws -> Void,
        updateLocal: (Message.ID) -> Void
    ) async {
        guard let session else { return }
        guard let actions = session.provider as? any MailActionsProvider else { return }
        guard !selectedIDs.isEmpty else { return }

        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        let ids = Array(selectedIDs)
        for id in ids {
            if Task.isCancelled { break }
            do {
                try await server(actions, id)
                updateLocal(id)
            } catch let err as MailError {
                lastError = err
                break
            } catch {
                lastError = .network(.unknown)
                break
            }
        }
    }
}
