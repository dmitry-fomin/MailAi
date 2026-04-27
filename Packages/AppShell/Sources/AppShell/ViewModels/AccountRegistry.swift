import Foundation
import Combine
import Core
import Secrets
import Storage
import GRDB

/// Реестр аккаунтов приложения. Хранит список доступных аккаунтов и кэш
/// `AccountSessionModel` по `Account.ID`, чтобы при повторном открытии окна
/// для того же аккаунта SwiftUI мог переиспользовать уже подготовленную
/// сессию (и не загружать мэйлбоксы дважды).
///
/// Дубль-окна для одного аккаунта предотвращаются механизмом SwiftUI:
/// `WindowGroup(for: Account.ID.self)` автоматически фокусирует уже
/// открытое окно с тем же значением.
@MainActor
public final class AccountRegistry: ObservableObject {
    @Published public private(set) var accounts: [Account]
    public let mode: AppShellMode
    public let selectionPersistence: any SelectionPersistence
    public let secrets: (any SecretsStore)?
    public let dbPaths: DatabasePathProvider?

    private var sessions: [Account.ID: AccountSessionModel] = [:]
    private var stores: [Account.ID: any MetadataStore] = [:]
    private var sessionCancellables: [Account.ID: AnyCancellable] = [:]

    public init(
        accounts: [Account] = [],
        mode: AppShellMode,
        selectionPersistence: any SelectionPersistence = DefaultsSelectionPersistence(),
        secrets: (any SecretsStore)? = nil,
        dbPaths: DatabasePathProvider? = nil
    ) {
        self.accounts = accounts
        self.mode = mode
        self.selectionPersistence = selectionPersistence
        self.secrets = secrets
        self.dbPaths = dbPaths
    }

    public func register(_ account: Account) {
        guard !accounts.contains(where: { $0.id == account.id }) else { return }
        accounts.append(account)
    }

    /// Регистрирует аккаунт вместе с уже готовым `AccountDataProvider`.
    /// Используется, когда provider нужно собрать явно (например, mock-режим
    /// внутри `.live`-реестра для кнопки «Продолжить с демо-данными»).
    public func register(_ account: Account, provider: any AccountDataProvider) {
        register(account)
        if sessions[account.id] == nil {
            let session = AccountSessionModel(
                account: account,
                provider: provider,
                selectionPersistence: selectionPersistence
            )
            sessions[account.id] = session
            observeSessionChanges(session)
        }
    }

    public func account(with id: Account.ID) -> Account? {
        accounts.first(where: { $0.id == id })
    }

    /// Возвращает (или лениво создаёт) сессию окна для указанного аккаунта.
    public func session(for id: Account.ID) -> AccountSessionModel? {
        if let existing = sessions[id] { return existing }
        guard let account = account(with: id) else { return nil }
        let store = persistentStore(for: account)
        stores[id] = store
        let provider = AccountDataProviderFactory.make(
            for: account,
            mode: mode,
            secrets: secrets,
            store: store
        )
        // Search-2: поисковый сервис на том же GRDB-pool.
        let search: (any SearchService)? = (store as? GRDBMetadataStore).map {
            GRDBSearchService(pool: $0.pool)
        }
        let session = AccountSessionModel(
            account: account,
            provider: provider,
            selectionPersistence: selectionPersistence,
            searchService: search
        )
        sessions[id] = session
        observeSessionChanges(session)
        return session
    }

    /// Собирает `MetadataStore` на диске (GRDB) на аккаунт, если у реестра
    /// настроен `DatabasePathProvider`. Иначе отдаёт in-memory — подходит
    /// для mock-режима и тестов.
    private func persistentStore(for account: Account) -> any MetadataStore {
        if let existing = stores[account.id] { return existing }
        guard let dbPaths else { return InMemoryMetadataStore() }
        let url = dbPaths.url(forAccountID: account.id.rawValue)
        do {
            return try GRDBMetadataStore(url: url)
        } catch {
            assertionFailure("Не смогли открыть GRDBMetadataStore: \(error)")
            return InMemoryMetadataStore()
        }
    }

    /// Возвращает GRDB pool для аккаунта, если хранилище — `GRDBMetadataStore`.
    /// Используется для построения `RulesRepository` в Settings.
    public func databasePool(for accountID: Account.ID) -> DatabasePool? {
        if let store = stores[accountID] as? GRDBMetadataStore {
            return store.pool
        }
        guard let account = account(with: accountID) else { return nil }
        let store = persistentStore(for: account)
        stores[accountID] = store
        return (store as? GRDBMetadataStore)?.pool
    }

    /// Сбрасывает сессию — вызывается при закрытии последнего окна аккаунта,
    /// чтобы инвариант «тело только в памяти пока открыто» не держал данные.
    public func releaseSession(for id: Account.ID) {
        sessions[id]?.closeSession()
        sessions.removeValue(forKey: id)
        sessionCancellables.removeValue(forKey: id)
    }

    // MARK: - Unread Count (StatusBar)

    /// Количество непрочитанных для аккаунта с активной сессией.
    /// Считается по `mailboxes[].unreadCount` (серверные данные).
    /// Возвращает 0, если сессия не создана или мэйлбоксы ещё не загружены.
    public func unreadCount(for accountID: Account.ID) -> Int {
        guard let session = sessions[accountID] else { return 0 }
        return session.mailboxes.reduce(0) { $0 + $1.unreadCount }
    }

    /// Общее количество непрочитанных по всем активным сессиям.
    /// Используется бейджем StatusBar.
    public var totalUnreadCount: Int {
        sessions.values.reduce(0) { sum, session in
            sum + session.mailboxes.reduce(0) { $0 + $1.unreadCount }
        }
    }

    /// Подписывается на `objectWillChange` сессии, чтобы изменения в
    /// мэйлбоксах/письмах каскадно обновляли StatusBar.
    private func observeSessionChanges(_ session: AccountSessionModel) {
        let id = session.account.id
        sessionCancellables[id] = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}
