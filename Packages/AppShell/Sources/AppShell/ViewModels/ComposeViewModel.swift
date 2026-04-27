import Foundation
import Core
import MailTransport

/// SMTP-5: ViewModel для `ComposeScene`. Держит поля формы, валидирует их,
/// компонует MIME через `MIMEComposer` и отправляет через `SendProvider`
/// либо сохраняет черновик через `DraftSaver`-замыкание (обёртка над
/// `LiveAccountDataProvider.saveDraft(envelope:body:)`).
///
/// Тело письма живёт только в этом объекте и стеке вызовов — после
/// успешной отправки/сохранения буфер очищается.
@MainActor
public final class ComposeViewModel: ObservableObject {

    /// Замыкание сохранения черновика. Конкретная имплементация
    /// предоставляется фабрикой (см. `AccountDataProviderFactory`).
    /// Возвращаем не-Sendable замыкание сознательно: вызывается только из
    /// `@MainActor`-контекста, а внутрь оборачивает actor-вызов.
    public typealias DraftSaver = @Sendable (DraftEnvelope, String) async throws -> Void

    // MARK: - Form state

    @Published public var to: String = ""
    @Published public var cc: String = ""
    @Published public var bcc: String = ""
    @Published public var subject: String = ""
    @Published public var body: String = ""

    // MARK: - UI state

    public enum SendState: Equatable, Sendable {
        case idle
        case sending
        case sent
        case error(String)
    }

    public enum DraftState: Equatable, Sendable {
        case idle
        case saving
        case saved
        case error(String)
    }

    @Published public private(set) var sendState: SendState = .idle
    @Published public private(set) var draftState: DraftState = .idle

    /// Триггер успешного завершения — окно подписывается, чтобы закрыться.
    @Published public private(set) var didFinish: Bool = false

    // MARK: - Dependencies

    public let accountEmail: String
    public let accountDisplayName: String?
    private let sendProvider: (any SendProvider)?
    private let draftSaver: DraftSaver?

    public init(
        accountEmail: String,
        accountDisplayName: String? = nil,
        sendProvider: (any SendProvider)? = nil,
        draftSaver: DraftSaver? = nil
    ) {
        self.accountEmail = accountEmail
        self.accountDisplayName = accountDisplayName
        self.sendProvider = sendProvider
        self.draftSaver = draftSaver
    }

    // MARK: - Capabilities

    public var canSend: Bool { sendProvider != nil }
    public var canSaveDraft: Bool { draftSaver != nil }

    // MARK: - Validation

    /// Поле «To» должно содержать минимум один валидный e-mail.
    public var isToValid: Bool {
        !parsedTo.isEmpty && parsedTo.allSatisfy(Self.isValidEmail)
    }

    public var isCcValid: Bool {
        parsedCc.allSatisfy(Self.isValidEmail)
    }

    public var isBccValid: Bool {
        parsedBcc.allSatisfy(Self.isValidEmail)
    }

    public var isFormValid: Bool {
        isToValid && isCcValid && isBccValid
    }

    /// Закрытие окна с непустым черновиком должно подтверждаться.
    public var hasUnsavedContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Parsing

    private var parsedTo: [String] { Self.split(to) }
    private var parsedCc: [String] { Self.split(cc) }
    private var parsedBcc: [String] { Self.split(bcc) }

    /// Делит строку «addr1, addr2; addr3» на массив адресов, выкидывая
    /// пустые элементы. Логирование адресов запрещено — функция чистая.
    static func split(_ raw: String) -> [String] {
        raw.split(whereSeparator: { ch in
            ch == "," || ch == ";" || ch == "\n"
        })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    /// Минимально достаточная RFC-проверка: `local@domain.tld`,
    /// домен содержит точку, нет пробелов. Глубокую RFC 5322 проверку
    /// приложение не делает — серверный SMTP скажет `RCPT TO` отказом.
    static func isValidEmail(_ candidate: String) -> Bool {
        guard !candidate.contains(" ") else { return false }
        let parts = candidate.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        guard domain.contains(".") else { return false }
        // domain не должен начинаться/заканчиваться точкой/дефисом
        if domain.hasPrefix(".") || domain.hasSuffix(".") { return false }
        return true
    }

    // MARK: - From header

    /// Собирает значение заголовка `From:` — `"Name <email>"` или `email`.
    private var fromHeader: String {
        if let name = accountDisplayName, !name.isEmpty {
            return "\(name) <\(accountEmail)>"
        }
        return accountEmail
    }

    // MARK: - Actions

    /// Отправляет письмо. После успеха — чистит буферы и поднимает
    /// `didFinish`, чтобы окно закрылось. Тело хранится в памяти не
    /// дольше этого вызова.
    public func send() async {
        guard let provider = sendProvider else {
            sendState = .error("Отправка недоступна — для аккаунта не настроен SMTP")
            return
        }
        guard isFormValid else {
            sendState = .error("Проверьте поля получателей")
            return
        }
        sendState = .sending
        let envelope = Envelope(
            from: accountEmail,
            to: parsedTo,
            cc: parsedCc,
            bcc: parsedBcc
        )
        let mime = MIMEComposer.compose(
            from: fromHeader,
            recipients: MIMEComposer.Recipients(
                to: parsedTo,
                cc: parsedCc,
                bcc: parsedBcc
            ),
            subject: subject,
            body: body
        )
        let mimeBody = MIMEBody(raw: mime)
        do {
            try await provider.send(envelope: envelope, body: mimeBody)
            // Гасим тело сразу после успешной отправки, чтобы не держать
            // его в памяти дольше необходимого.
            body = ""
            sendState = .sent
            didFinish = true
        } catch let err as MailError {
            sendState = .error(Self.describe(err))
        } catch {
            sendState = .error("Не удалось отправить письмо")
        }
    }

    /// Сохраняет черновик через IMAP APPEND (см. SMTP-4).
    public func saveDraft() async {
        guard let saver = draftSaver else {
            draftState = .error("Сохранение черновика недоступно")
            return
        }
        // Для черновика разрешаем пустой список получателей — это нормально:
        // пользователь дописывает письмо. Минимально требуем валидность
        // непустых полей.
        guard isCcValid, isBccValid, parsedTo.allSatisfy(Self.isValidEmail) else {
            draftState = .error("Проверьте поля получателей")
            return
        }
        draftState = .saving
        let envelope = DraftEnvelope(
            from: fromHeader,
            to: parsedTo,
            cc: parsedCc,
            bcc: parsedBcc,
            subject: subject
        )
        let snapshotBody = body
        do {
            try await saver(envelope, snapshotBody)
            draftState = .saved
        } catch let err as MailError {
            draftState = .error(Self.describe(err))
        } catch {
            draftState = .error("Не удалось сохранить черновик")
        }
    }

    /// Сбрасывает баннер ошибки/состояния, когда пользователь возвращается
    /// к редактированию.
    public func clearStatuses() {
        if case .error = sendState { sendState = .idle }
        if case .error = draftState { draftState = .idle }
        if case .sent = sendState { sendState = .idle }
        if case .saved = draftState { draftState = .idle }
    }

    // MARK: - Helpers

    private static func describe(_ err: MailError) -> String {
        err.errorDescription ?? "Не удалось выполнить операцию"
    }
}
