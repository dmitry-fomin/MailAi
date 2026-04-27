import Foundation
import Core
import Secrets

/// Реальная реализация `SendProvider`: открывает SMTP-сессию через
/// `SMTPConnection.withOpen`, отправляет одно письмо и закрывает соединение.
///
/// Особенности:
/// - SMTP-endpoint берётся из `Account.smtpHost/smtpPort/smtpSecurity`.
///   Если эти поля не заданы — отправка запрещена (`MailError.unsupported`).
/// - Пароль ищется сначала в `SecretsStore.smtpPassword(forAccount:)`,
///   а при его отсутствии — в обычном `password(forAccount:)` (IMAP-пароль).
///   Это удобно, когда у пользователя один пароль для IMAP и SMTP.
/// - Тело письма (`MIMEBody.raw`) живёт только в стеке вызова и не
///   попадает в логи.
public actor LiveSendProvider: SendProvider {
    public let account: Account
    private let secrets: any SecretsStore
    private let endpoint: SMTPEndpoint

    public init(
        account: Account,
        secrets: any SecretsStore,
        endpoint: SMTPEndpoint? = nil
    ) throws {
        self.account = account
        self.secrets = secrets
        if let endpoint {
            self.endpoint = endpoint
        } else {
            guard let resolved = Self.resolveEndpoint(for: account) else {
                throw MailError.unsupported(
                    "У аккаунта не настроен SMTP — заполните smtpHost/smtpPort/smtpSecurity или передайте endpoint явно."
                )
            }
            self.endpoint = resolved
        }
    }

    /// Маппит SMTP-поля `Account` в `SMTPEndpoint`. Возвращает `nil`,
    /// если хоть одно поле не задано.
    public static func resolveEndpoint(for account: Account) -> SMTPEndpoint? {
        guard
            let host = account.smtpHost, !host.isEmpty,
            let port = account.smtpPort,
            let security = account.smtpSecurity
        else {
            return nil
        }
        return SMTPEndpoint(
            host: host,
            port: Int(port),
            security: Self.mapSecurity(security)
        )
    }

    private static func mapSecurity(_ security: Account.Security) -> SMTPEndpoint.Security {
        switch security {
        case .tls:      return .tls
        case .startTLS: return .startTLS
        case .none:     return .plain
        }
    }

    public func send(envelope: Envelope, body: MIMEBody) async throws {
        guard !envelope.from.isEmpty else {
            throw MailError.unsupported("Envelope.from не должен быть пустым")
        }
        let recipients = envelope.recipients
        guard !recipients.isEmpty else {
            throw MailError.unsupported("Envelope: список получателей пуст")
        }
        let password = try await resolvePassword()
        let credentials = SMTPCredentials(
            username: account.username,
            password: password
        )
        try await SMTPConnection.withOpen(
            endpoint: endpoint,
            credentials: credentials
        ) { conn in
            try await conn.send(
                from: envelope.from,
                to: recipients,
                data: body.raw
            )
            try? await conn.quit()
        }
    }

    /// Сначала пробуем выделенный SMTP-пароль; если не задан — fallback
    /// на IMAP-пароль того же аккаунта.
    private func resolvePassword() async throws -> String {
        if let dedicated = try await secrets.smtpPassword(forAccount: account.id),
           !dedicated.isEmpty {
            return dedicated
        }
        if let imap = try await secrets.password(forAccount: account.id),
           !imap.isEmpty {
            return imap
        }
        throw MailError.keychain(.unknown)
    }
}
