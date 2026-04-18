import Foundation
import Core

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

    private var sessions: [Account.ID: AccountSessionModel] = [:]

    public init(accounts: [Account] = [], mode: AppShellMode) {
        self.accounts = accounts
        self.mode = mode
    }

    public func register(_ account: Account) {
        guard !accounts.contains(where: { $0.id == account.id }) else { return }
        accounts.append(account)
    }

    public func account(with id: Account.ID) -> Account? {
        accounts.first(where: { $0.id == id })
    }

    /// Возвращает (или лениво создаёт) сессию окна для указанного аккаунта.
    public func session(for id: Account.ID) -> AccountSessionModel? {
        if let existing = sessions[id] { return existing }
        guard let account = account(with: id) else { return nil }
        let provider = AccountDataProviderFactory.make(for: account, mode: mode)
        let session = AccountSessionModel(account: account, provider: provider)
        sessions[id] = session
        return session
    }

    /// Сбрасывает сессию — вызывается при закрытии последнего окна аккаунта,
    /// чтобы инвариант «тело только в памяти пока открыто» не держал данные.
    public func releaseSession(for id: Account.ID) {
        sessions[id]?.closeSession()
        sessions.removeValue(forKey: id)
    }
}
