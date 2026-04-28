import Foundation
import Core
import Storage

/// ViewModel для экрана «Подписи» в настройках.
///
/// Управляет списком подписей: загрузка, добавление, удаление,
/// сохранение выбранной записи. Все мутации — через `SignaturesRepository`.
@MainActor
public final class SignaturesViewModel: ObservableObject {

    // MARK: - Published state

    /// Полный список подписей.
    @Published public private(set) var signatures: [Signature] = []

    /// Идентификатор выбранной подписи (выделена в левом списке).
    @Published public var selectedID: Signature.ID?

    // MARK: - Dependencies

    private let repository: SignaturesRepository

    // MARK: - Init

    public init(repository: SignaturesRepository) {
        self.repository = repository
    }

    // MARK: - Computed

    /// Подпись, соответствующая `selectedID`, если она существует.
    public var selected: Signature? {
        guard let id = selectedID else { return nil }
        return signatures.first { $0.id == id }
    }

    // MARK: - Load

    /// Загружает все подписи из базы и обновляет список.
    public func load() async {
        do {
            signatures = try await repository.all()
        } catch {
            // Не логируем тела подписей; ошибку БД показываем в консоли для отладки.
            print("[SignaturesViewModel] load error: \(error)")
        }
    }

    // MARK: - Add

    /// Создаёт новую подпись с placeholder-именем и сразу выбирает её.
    public func add() async {
        let newSig = Signature(name: "Без названия", body: "")
        do {
            try await repository.upsert(newSig)
            signatures = try await repository.all()
            selectedID = newSig.id
        } catch {
            print("[SignaturesViewModel] add error: \(error)")
        }
    }

    // MARK: - Delete

    /// Удаляет подпись с указанным `id`. Если она была выбрана — сбрасывает выбор.
    public func delete(_ id: Signature.ID) async {
        do {
            try await repository.delete(id: id)
            signatures = try await repository.all()
            if selectedID == id {
                selectedID = signatures.first?.id
            }
        } catch {
            print("[SignaturesViewModel] delete error: \(error)")
        }
    }

    // MARK: - Save

    /// Сохраняет изменения выбранной подписи.
    ///
    /// Если `isDefault == true` — вызывает `setDefault`, чтобы снять флаг
    /// со всех остальных записей.
    public func save(name: String, body: String, isDefault: Bool) async {
        guard let id = selectedID else { return }
        let updated = Signature(id: id, name: name, body: body, isDefault: isDefault)
        do {
            try await repository.upsert(updated)
            if isDefault {
                try await repository.setDefault(id: id)
            }
            signatures = try await repository.all()
        } catch {
            print("[SignaturesViewModel] save error: \(error)")
            // БАГ-9: синхронизируем UI с БД даже при ошибке, чтобы не показывать
            // устаревшие данные (например, upsert прошёл, но setDefault упал).
            if let all = try? await repository.all() {
                signatures = all
            }
        }
    }
}
