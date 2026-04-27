import Foundation
import Core
import Secrets
import MailTransport

/// Состояние формы добавления Exchange-аккаунта (EWS/on-premise).
/// Пробует Autodiscover автоматически; можно ввести URL вручную.
@MainActor
public final class ExchangeOnboardingViewModel: ObservableObject {

    public enum Phase: Equatable, Sendable {
        case editing
        case discovering  // Autodiscover в процессе
        case validating   // Проверка подключения
        case failed(String)
        case succeeded(Account)
    }

    // MARK: - Form fields

    @Published public var email: String = ""
    @Published public var password: String = ""
    @Published public var displayName: String = ""
    @Published public var ewsURLOverride: String = ""  // пусто = Autodiscover
    @Published public var showManualURL: Bool = false

    @Published public private(set) var phase: Phase = .editing
    @Published public private(set) var discoveredURLString: String = ""

    private let secretsStore: any SecretsStore
    private let registry: AccountRegistry

    public init(secretsStore: any SecretsStore, registry: AccountRegistry) {
        self.secretsStore = secretsStore
        self.registry = registry
    }

    // MARK: - Derived

    public var canSubmit: Bool {
        guard case .editing = phase else { return false }
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty else { return false }
        if showManualURL {
            return !ewsURLOverride.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    // MARK: - Actions

    public func submit() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let pwd = password
        let dname = displayName.trimmingCharacters(in: .whitespaces)

        // Определяем EWS URL
        let ewsURL: URL
        if showManualURL, let manualURL = URL(string: ewsURLOverride.trimmingCharacters(in: .whitespaces)) {
            ewsURL = manualURL
        } else {
            phase = .discovering
            do {
                ewsURL = try await EWSClient.autodiscover(email: trimmedEmail, password: pwd)
                discoveredURLString = ewsURL.absoluteString
            } catch {
                phase = .failed("Не удалось обнаружить сервер Exchange. Введите EWS URL вручную.")
                showManualURL = true
                return
            }
        }

        phase = .validating

        // Проверяем подключение — делаем GetFolder inbox
        let client = EWSClient(
            ewsURL: ewsURL,
            username: trimmedEmail,
            password: pwd
        )
        do {
            let folders = try await client.getFolders(ids: [.inbox])
            guard !folders.isEmpty else {
                throw MailError.protocolViolation("Сервер вернул пустой список папок")
            }

            // Собираем Account
            let host = ewsURL.host ?? ewsURL.absoluteString
            let port = UInt16(ewsURL.port ?? 443)
            let accountID = Account.ID(trimmedEmail + "@ews@" + host)
            let account = Account(
                id: accountID,
                email: trimmedEmail,
                displayName: dname.isEmpty ? nil : dname,
                kind: .exchange,
                host: host,
                port: port,
                security: ewsURL.scheme == "https" ? .tls : .none,
                username: trimmedEmail
            )

            try await secretsStore.setPassword(pwd, forAccount: accountID)
            // Сохраняем EWS URL как отдельный секрет (reuse password slot с префиксом)
            try await secretsStore.setPassword(ewsURL.absoluteString, forAccount: Account.ID(accountID.rawValue + ":ewsURL"))

            registry.register(account)
            password = ""
            phase = .succeeded(account)
        } catch {
            phase = .failed(humanReadable(error))
        }
    }

    public func resetError() {
        if case .failed = phase { phase = .editing }
    }

    // MARK: - Error mapping

    private func humanReadable(_ error: any Error) -> String {
        if let mail = error as? MailError {
            switch mail {
            case .authentication: return "Неверный логин или пароль."
            case .network(let r): return "Сетевая ошибка (\(r.rawValue)). Проверьте адрес сервера."
            case .protocolViolation(let s): return "Ошибка протокола: \(s)"
            default: return mail.localizedDescription
            }
        }
        return "Не удалось подключиться: \(error.localizedDescription)"
    }
}
