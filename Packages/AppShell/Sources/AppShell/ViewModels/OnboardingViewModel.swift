import Foundation
import Core
import Secrets
import MailTransport

/// Состояние формы онбординга IMAP-аккаунта.
///
/// Принципы:
/// - Пароль хранится в `@Published`-поле только на время жизни view-model;
///   после успешной валидации он уходит в `SecretsStore` (Keychain в проде)
///   и тут же стирается. В Account/Storage паролей нет — только `username`
///   и `Account.ID`, по которым Secrets достаёт значение.
/// - LOGIN-проверка делается реальным `IMAPConnection` с теми же параметрами,
///   что пользователь ввёл. Дополнительно делаем `SELECT INBOX` — это
///   «первый FETCH INBOX» из C4: подтверждаем, что на сервере есть INBOX,
///   и что аккаунт рабочий.
/// - SMTP-поля автозаполняются через `IMAPAutoconfig` при вводе email.
///   Если автоопределение не дало результата — пользователь вводит вручную.
/// - Если `smtpUseSamePassword == true`, SMTP-пароль = IMAP-пароль (по умолчанию).
///   Иначе — хранится отдельно в Keychain (`SecretsStore.setSMTPPassword`).
@MainActor
public final class OnboardingViewModel: ObservableObject {

    public enum Phase: Equatable, Sendable {
        case editing
        case validating
        case failed(String)
        case succeeded(Account)
    }

    // MARK: - Form fields: IMAP

    @Published public var email: String = ""
    @Published public var password: String = ""
    @Published public var host: String = ""
    @Published public var portText: String = "993"
    @Published public var useTLS: Bool = true
    @Published public var username: String = ""
    @Published public var displayName: String = ""

    // MARK: - Form fields: SMTP

    /// Отображать ли SMTP-секцию (true, когда автоопределение завершено или недоступно).
    @Published public var showSMTPSection: Bool = false

    @Published public var smtpHost: String = ""
    @Published public var smtpPortText: String = "587"

    /// Режим шифрования SMTP: true = SSL (порт 465), false = STARTTLS (порт 587).
    @Published public var smtpUseTLS: Bool = false

    /// Использовать тот же пароль для SMTP, что и для IMAP (по умолчанию).
    @Published public var smtpUseSamePassword: Bool = true

    /// Отдельный SMTP-пароль (используется только если `smtpUseSamePassword == false`).
    @Published public var smtpPassword: String = ""

    // MARK: - Autoconfig state

    /// true — идёт автоопределение настроек.
    @Published public private(set) var isAutoconfiguring: Bool = false

    // MARK: - Phase

    @Published public private(set) var phase: Phase = .editing

    // MARK: - Dependencies

    private let secretsStore: any SecretsStore
    private let registry: AccountRegistry
    private let imapConnect: @Sendable (IMAPEndpoint) async throws -> any IMAPLoginCapable
    private let autoconfig: IMAPAutoconfig

    public init(
        secretsStore: any SecretsStore,
        registry: AccountRegistry,
        imapConnect: (@Sendable (IMAPEndpoint) async throws -> any IMAPLoginCapable)? = nil,
        autoconfig: IMAPAutoconfig = IMAPAutoconfig()
    ) {
        self.secretsStore = secretsStore
        self.registry = registry
        self.imapConnect = imapConnect ?? { endpoint in
            try await RealIMAPLogin.make(endpoint: endpoint)
        }
        self.autoconfig = autoconfig
    }

    // MARK: - Derived

    public var canSubmit: Bool {
        if case .validating = phase { return false }
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty,
              !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let port = parsedPort, (1...65535).contains(Int(port)) else {
            return false
        }
        if showSMTPSection {
            guard !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty,
                  let smtpPort = parsedSMTPPort, (1...65535).contains(Int(smtpPort)) else {
                return false
            }
            if !smtpUseSamePassword && smtpPassword.isEmpty {
                return false
            }
        }
        return true
    }

    public var parsedPort: UInt16? {
        UInt16(portText.trimmingCharacters(in: .whitespaces))
    }

    public var parsedSMTPPort: UInt16? {
        UInt16(smtpPortText.trimmingCharacters(in: .whitespaces))
    }

    public var resolvedUsername: String {
        let u = username.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? email.trimmingCharacters(in: .whitespaces) : u
    }

    // MARK: - Autoconfig

    /// Запускает автоопределение IMAP/SMTP настроек по домену email.
    /// Вызывается из View при потере фокуса поля email.
    public func runAutoconfig() async {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isAutoconfiguring = true
        defer { isAutoconfiguring = false }

        do {
            let result = try await autoconfig.discover(email: trimmed)
            // Заполняем IMAP-поля только если пользователь ещё не ввёл их вручную.
            if host.trimmingCharacters(in: .whitespaces).isEmpty {
                host = result.imapHost
                portText = String(result.imapPort)
                useTLS = result.imapSecurity == .ssl
            }
            // SMTP-поля заполняем из результата.
            smtpHost = result.smtpHost
            smtpPortText = String(result.smtpPort)
            smtpUseTLS = result.smtpSecurity == .ssl
            showSMTPSection = true
        } catch AutoconfigError.invalidEmail {
            // Невалидный email — не показываем SMTP-секцию.
            showSMTPSection = false
        } catch {
            // Не удалось определить — показываем секцию для ручного ввода.
            showSMTPSection = true
        }
    }

    // MARK: - Submit

    public func submit() async {
        guard canSubmit, let port = parsedPort else { return }
        phase = .validating

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let user = resolvedUsername
        let pwd = password  // локальная копия, чтобы затем очистить поле
        let smtpPwd = smtpUseSamePassword ? pwd : smtpPassword

        let endpoint = IMAPEndpoint(
            host: trimmedHost,
            port: Int(port),
            security: useTLS ? .tls : .plain
        )
        // БАГ-11: используем percent-encoding чтобы избежать коллизий если email/host
        // содержат '@' или ':'. Альтернатива — UUID, но тогда нельзя
        // детерминированно восстановить ID при перезапуске по тем же данным.
        let encodedEmail = trimmedEmail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedEmail
        let encodedHost = trimmedHost.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedHost
        let accountID = Account.ID(encodedEmail + "@" + encodedHost + ":" + String(port))

        // Строим Account с SMTP-полями если они заданы.
        let resolvedSMTPHost: String?
        let resolvedSMTPPort: UInt16?
        let resolvedSMTPSecurity: Account.Security?
        if showSMTPSection,
           !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty,
           let sp = parsedSMTPPort {
            resolvedSMTPHost = smtpHost.trimmingCharacters(in: .whitespaces)
            resolvedSMTPPort = sp
            resolvedSMTPSecurity = smtpUseTLS ? .tls : .startTLS
        } else {
            resolvedSMTPHost = nil
            resolvedSMTPPort = nil
            resolvedSMTPSecurity = nil
        }

        let account = Account(
            id: accountID,
            email: trimmedEmail,
            displayName: displayName.isEmpty ? nil : displayName,
            kind: .imap,
            host: trimmedHost,
            port: port,
            security: useTLS ? .tls : .none,
            username: user,
            smtpHost: resolvedSMTPHost,
            smtpPort: resolvedSMTPPort,
            smtpSecurity: resolvedSMTPSecurity
        )

        do {
            let session = try await imapConnect(endpoint)
            try await session.run { conn in
                try await conn.login(username: user, password: pwd)
                // Первый FETCH INBOX — проверяем, что аккаунт живой.
                _ = try await conn.select("INBOX")
                try await conn.logout()
            }
            try await secretsStore.setPassword(pwd, forAccount: accountID)
            // Сохраняем SMTP-пароль только если он отличается от IMAP.
            if !smtpUseSamePassword && !smtpPwd.isEmpty {
                try await secretsStore.setSMTPPassword(smtpPwd, forAccount: accountID)
            }
            registry.register(account)
            password = ""       // не держим пароль в памяти после сохранения
            smtpPassword = ""   // очищаем и SMTP-пароль
            phase = .succeeded(account)
        } catch {
            phase = .failed(Self.humanReadable(error))
        }
    }

    public func resetError() {
        if case .failed = phase { phase = .editing }
    }

    // MARK: - Error mapping

    static func humanReadable(_ error: any Error) -> String {
        if let imap = error as? IMAPConnectionError {
            switch imap {
            case .channelClosed:
                return "Сервер закрыл соединение. Проверьте host/port и TLS."
            case .greetingMissing, .unexpectedGreeting:
                return "Сервер не ответил валидным IMAP-приветствием."
            case .commandFailed(let status, let text):
                return "IMAP \(status.rawValue): \(text)"
            }
        }
        return "Не удалось подключиться: \(error.localizedDescription)"
    }
}

// MARK: - Injection seam

/// Абстракция «IMAP-сессия в замыкании», чтобы ViewModel можно было мокать
/// в тестах без поднятия реального NIO-сервера.
public protocol IMAPLoginCapable: Sendable {
    func run(_ body: @Sendable (IMAPConnection) async throws -> Void) async throws
}

/// Реальная реализация — обёртка над `IMAPConnection.withOpen(endpoint:)`.
struct RealIMAPLogin: IMAPLoginCapable {
    let endpoint: IMAPEndpoint

    static func make(endpoint: IMAPEndpoint) async throws -> RealIMAPLogin {
        RealIMAPLogin(endpoint: endpoint)
    }

    func run(_ body: @Sendable (IMAPConnection) async throws -> Void) async throws {
        try await IMAPConnection.withOpen(endpoint: endpoint) { conn in
            try await body(conn)
        }
    }
}
