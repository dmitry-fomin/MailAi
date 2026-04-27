// SMTPProviderSmoke — smoke-тесты SendProvider/LiveSendProvider.
// Запуск: swift run SMTPProviderSmoke
//
// Проверяет:
// - Envelope: recipients = to + cc + bcc, bcc корректно отделён.
// - LiveSendProvider.resolveEndpoint(for:) — корректный mapping
//   smtpHost/smtpPort/smtpSecurity → SMTPEndpoint.
// - LiveSendProvider бросает MailError.unsupported, если SMTP не настроен.
// - LiveSendProvider бросает MailError.keychain, если пароля нет
//   ни в smtpPassword, ни в password.
// - send() с пустым envelope.from / пустыми recipients падает.
//
// Без сетевых вызовов — для них есть SMTPSmoke (требует ENV-переменные).

import Foundation
import Core
import Secrets
import MailTransport

// MARK: - Хелперы

func assertTrue(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    precondition(lhs == rhs, "\(message): \(lhs) != \(rhs)")
}

func assertThrows(_ message: String, _ block: () async throws -> Void) async {
    do {
        try await block()
        preconditionFailure("\(message): expected throw, got success")
    } catch {
        // OK
    }
}

// MARK: - Аккаунты для тестов

func makeAccount(
    smtpHost: String? = "smtp.example.com",
    smtpPort: UInt16? = 587,
    smtpSecurity: Account.Security? = .startTLS
) -> Account {
    Account(
        id: Account.ID("smoke-\(UUID().uuidString)"),
        email: "alice@example.com",
        displayName: "Alice",
        kind: .imap,
        host: "imap.example.com",
        port: 993,
        security: .tls,
        username: "alice@example.com",
        smtpHost: smtpHost,
        smtpPort: smtpPort,
        smtpSecurity: smtpSecurity
    )
}

// MARK: - Тесты

func testEnvelopeRecipients() {
    let env = Envelope(
        from: "alice@example.com",
        to: ["bob@example.com"],
        cc: ["carol@example.com"],
        bcc: ["secret@example.com"]
    )
    assertEqual(
        env.recipients,
        ["bob@example.com", "carol@example.com", "secret@example.com"],
        "Envelope.recipients = to + cc + bcc"
    )
    assertEqual(env.from, "alice@example.com", "from passthrough")

    let envEmpty = Envelope(from: "x@y.com", to: ["z@w.com"])
    assertEqual(envEmpty.cc, [], "default cc empty")
    assertEqual(envEmpty.bcc, [], "default bcc empty")
    assertEqual(envEmpty.recipients, ["z@w.com"], "только to при пустых cc/bcc")

    print("✅ Envelope: recipients/from")
}

func testResolveEndpointHappy() {
    let acc = makeAccount(smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls)
    guard let ep = LiveSendProvider.resolveEndpoint(for: acc) else {
        preconditionFailure("Endpoint должен резолвиться")
    }
    assertEqual(ep.host, "smtp.gmail.com", "host из smtpHost")
    assertEqual(ep.port, 465, "port из smtpPort")
    assertEqual(ep.security, .tls, "security mapping")

    let acc2 = makeAccount(smtpHost: "smtp.yandex.com", smtpPort: 587, smtpSecurity: .startTLS)
    let ep2 = LiveSendProvider.resolveEndpoint(for: acc2)!
    assertEqual(ep2.security, .startTLS, "startTLS mapping")

    let acc3 = makeAccount(smtpHost: "localhost", smtpPort: 2525, smtpSecurity: Account.Security.none)
    let ep3 = LiveSendProvider.resolveEndpoint(for: acc3)!
    assertEqual(ep3.security, .plain, "none → plain")

    print("✅ resolveEndpoint: happy path + security mapping")
}

func testResolveEndpointMissingFields() {
    assertTrue(
        LiveSendProvider.resolveEndpoint(for: makeAccount(smtpHost: nil)) == nil,
        "smtpHost nil → resolveEndpoint nil"
    )
    assertTrue(
        LiveSendProvider.resolveEndpoint(for: makeAccount(smtpPort: nil)) == nil,
        "smtpPort nil → resolveEndpoint nil"
    )
    assertTrue(
        LiveSendProvider.resolveEndpoint(for: makeAccount(smtpSecurity: nil)) == nil,
        "smtpSecurity nil → resolveEndpoint nil"
    )
    assertTrue(
        LiveSendProvider.resolveEndpoint(for: makeAccount(smtpHost: "")) == nil,
        "пустой smtpHost → resolveEndpoint nil"
    )
    print("✅ resolveEndpoint: nil при отсутствии полей")
}

func testInitFailsWhenSMTPNotConfigured() async {
    let acc = makeAccount(smtpHost: nil)
    let secrets = InMemorySecretsStore()
    do {
        _ = try LiveSendProvider(account: acc, secrets: secrets)
        preconditionFailure("Должен бросить MailError.unsupported")
    } catch let error as MailError {
        if case .unsupported = error {
            // OK
        } else {
            preconditionFailure("Ожидался MailError.unsupported, получили \(error)")
        }
    } catch {
        preconditionFailure("Ожидался MailError.unsupported, получили \(error)")
    }
    print("✅ init бросает MailError.unsupported при пустом SMTP")
}

func testSendFailsWithoutPassword() async throws {
    let acc = makeAccount()
    let secrets = InMemorySecretsStore()
    let provider = try LiveSendProvider(account: acc, secrets: secrets)
    let env = Envelope(from: "alice@example.com", to: ["bob@example.com"])
    let body = MIMEBody(raw: "Subject: t\r\n\r\nbody")

    do {
        try await provider.send(envelope: env, body: body)
        preconditionFailure("Должен бросить MailError.keychain")
    } catch let error as MailError {
        if case .keychain = error {
            // OK
        } else {
            preconditionFailure("Ожидался MailError.keychain, получили \(error)")
        }
    } catch {
        preconditionFailure("Ожидался MailError.keychain, получили \(error)")
    }
    print("✅ send без пароля → MailError.keychain")
}

func testSendValidatesEnvelope() async throws {
    let acc = makeAccount()
    let secrets = InMemorySecretsStore()
    // Кладём пароль, чтобы валидация envelope сработала раньше keychain-ошибки.
    try await secrets.setSMTPPassword("test-password", forAccount: acc.id)
    let provider = try LiveSendProvider(account: acc, secrets: secrets)
    let body = MIMEBody(raw: "")

    // Пустой from
    await assertThrows("send с пустым from должен упасть") {
        try await provider.send(
            envelope: Envelope(from: "", to: ["b@c.com"]),
            body: body
        )
    }

    // Пустой список получателей
    await assertThrows("send без получателей должен упасть") {
        try await provider.send(
            envelope: Envelope(from: "a@b.com", to: []),
            body: body
        )
    }

    print("✅ send валидирует envelope (from / recipients)")
}

func testSecretsFallbackOrder() async throws {
    let acc = makeAccount()
    let secrets = InMemorySecretsStore()
    // smtpPassword отсутствует, есть только IMAP-пароль.
    try await secrets.setPassword("imap-pwd", forAccount: acc.id)
    assertEqual(
        try await secrets.smtpPassword(forAccount: acc.id),
        nil,
        "smtpPassword пуст"
    )
    assertEqual(
        try await secrets.password(forAccount: acc.id),
        "imap-pwd",
        "IMAP-пароль доступен"
    )
    // Кладём выделенный SMTP-пароль — он должен иметь приоритет.
    try await secrets.setSMTPPassword("smtp-pwd", forAccount: acc.id)
    assertEqual(
        try await secrets.smtpPassword(forAccount: acc.id),
        "smtp-pwd",
        "smtpPassword прочитан"
    )
    // Удаление SMTP-пароля не трогает IMAP.
    try await secrets.deleteSMTPPassword(forAccount: acc.id)
    assertEqual(
        try await secrets.smtpPassword(forAccount: acc.id),
        nil,
        "smtpPassword удалён"
    )
    assertEqual(
        try await secrets.password(forAccount: acc.id),
        "imap-pwd",
        "IMAP-пароль не затронут"
    )
    print("✅ SecretsStore: SMTP-пароль независим от IMAP")
}

// MARK: - Запуск

@main
enum SMTPProviderSmokeMain {
    static func main() async throws {
        print("🧪 SMTPProviderSmoke")
        print(String(repeating: "=", count: 40))

        testEnvelopeRecipients()
        testResolveEndpointHappy()
        testResolveEndpointMissingFields()
        await testInitFailsWhenSMTPNotConfigured()
        try await testSendFailsWithoutPassword()
        try await testSendValidatesEnvelope()
        try await testSecretsFallbackOrder()

        print(String(repeating: "=", count: 40))
        print("✅ Все SMTPProviderSmoke-тесты пройдены!")
    }
}
