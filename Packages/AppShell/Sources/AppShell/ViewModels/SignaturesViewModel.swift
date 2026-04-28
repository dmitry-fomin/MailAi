import Foundation
import Core
import Storage

/// ViewModel для экрана «Подписи» в настройках.
///
/// Управляет списком подписей: загрузка, добавление, удаление,
/// сохранение выбранной записи. Все мутации — через `SignaturesRepository`.
///
/// MailAi-8uz8: поддерживает per-account фильтрацию и выбор подписи
/// по умолчанию, привязанной к конкретному аккаунту.
@MainActor
public final class SignaturesViewModel: ObservableObject {

    // MARK: - Published state

    /// Полный список подписей (или подписей для выбранного аккаунта).
    @Published public private(set) var signatures: [Signature] = []

    /// Идентификатор выбранной подписи (выделена в левом списке).
    @Published public var selectedID: Signature.ID?

    /// Текущий фильтр по аккаунту. nil — показываем все подписи.
    @Published public var filterAccountID: Account.ID?

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

    /// Загружает подписи из базы.
    ///
    /// Если `filterAccountID` задан — загружает подписи для этого аккаунта
    /// (привязанные + глобальные). Иначе — все.
    public func load() async {
        do {
            if let accountID = filterAccountID {
                signatures = try await repository.signatures(for: accountID)
            } else {
                signatures = try await repository.all()
            }
        } catch {
            // Не логируем тела подписей; ошибку БД показываем в консоли для отладки.
            print("[SignaturesViewModel] load error: \(error)")
        }
    }

    // MARK: - Add

    /// Создаёт новую подпись с placeholder-именем и сразу выбирает её.
    /// Если `filterAccountID` задан — подпись привязывается к этому аккаунту.
    public func add() async {
        let newSig = Signature(
            name: "Без названия",
            body: "",
            accountID: filterAccountID
        )
        do {
            try await repository.upsert(newSig)
            await reload()
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
            await reload()
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
    /// со всех остальных записей в рамках того же аккаунта (или глобально).
    public func save(name: String, body: String, isDefault: Bool, accountID: Account.ID? = nil) async {
        guard let id = selectedID else { return }
        let effectiveAccountID = accountID ?? selected?.accountID ?? filterAccountID
        let updated = Signature(id: id, name: name, body: body, isDefault: isDefault,
                                accountID: effectiveAccountID)
        do {
            try await repository.upsert(updated)
            if isDefault {
                try await repository.setDefault(id: id)
            }
            await reload()
        } catch {
            print("[SignaturesViewModel] save error: \(error)")
            // Синхронизируем UI с БД даже при ошибке, чтобы не показывать устаревшие данные.
            await reload()
        }
    }

    // MARK: - Default Signature (MailAi-8uz8)

    /// Возвращает подпись по умолчанию для указанного аккаунта.
    /// Используется `ComposeViewModel` для автовставки подписи в новое письмо.
    public func defaultSignature(for accountID: Account.ID) async -> Signature? {
        do {
            return try await repository.defaultSignature(for: accountID)
        } catch {
            print("[SignaturesViewModel] defaultSignature error: \(error)")
            return nil
        }
    }

    // MARK: - Private

    private func reload() async {
        do {
            if let accountID = filterAccountID {
                signatures = try await repository.signatures(for: accountID)
            } else {
                signatures = try await repository.all()
            }
        } catch {
            print("[SignaturesViewModel] reload error: \(error)")
        }
    }
}
