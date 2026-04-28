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

    // MARK: - Form state (tokens)

    /// Массивы токенов для полей адресатов.
    /// AddressTokenField работает напрямую с этими массивами.
    @Published public var toTokens: [String] = []
    @Published public var ccTokens: [String] = []
    @Published public var bccTokens: [String] = []

    @Published public var subject: String = ""
    @Published public var body: String = ""

    // MARK: - Attachments

    /// Прикреплённые файлы. Данные живут только в памяти до отправки / очистки.
    @Published public private(set) var attachedFiles: [ComposeAttachment] = []

    /// Суммарный размер всех вложений в байтах.
    public var totalAttachmentSize: Int {
        attachedFiles.reduce(0) { $0 + $1.size }
    }

    /// Предупреждение о большом размере вложений (>25 МБ).
    public var attachmentSizeWarning: String? {
        let limit = 25 * 1024 * 1024
        guard totalAttachmentSize > limit else { return nil }
        let mb = Double(totalAttachmentSize) / (1024 * 1024)
        return String(format: "Суммарный размер вложений %.1f МБ превышает рекомендуемые 25 МБ. Письмо может не дойти.", mb)
    }

    /// Добавляет файл по URL. Читает данные в память; тело файла не пишется на диск.
    public func attachFile(url: URL) {
        guard url.isFileURL else { return }
        guard (try? url.checkResourceIsReachable()) == true else { return }
        // Избегаем дублей по пути
        let path = url.path
        guard !attachedFiles.contains(where: { $0.url.path == path }) else { return }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let att = ComposeAttachment(
            url: url,
            filename: url.lastPathComponent,
            mimeType: mimeType(for: url),
            data: data
        )
        attachedFiles.append(att)
    }

    /// Удаляет вложение по ID.
    public func removeAttachment(id: ComposeAttachment.ID) {
        attachedFiles.removeAll { $0.id == id }
    }

    /// MIME-тип по расширению файла (простая эвристика).
    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Строковые алиасы (обратная совместимость)

    /// Строковое представление поля «Кому» для MIME и DraftEnvelope.
    public var to: String {
        get { toTokens.joined(separator: ", ") }
        set { toTokens = Self.split(newValue) }
    }

    public var cc: String {
        get { ccTokens.joined(separator: ", ") }
        set { ccTokens = Self.split(newValue) }
    }

    public var bcc: String {
        get { bccTokens.joined(separator: ", ") }
        set { bccTokens = Self.split(newValue) }
    }

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
        draftSaver: DraftSaver? = nil,
        defaultSignatureBody: String? = nil
    ) {
        self.accountEmail = accountEmail
        self.accountDisplayName = accountDisplayName
        self.sendProvider = sendProvider
        self.draftSaver = draftSaver
        if let sig = defaultSignatureBody, !sig.isEmpty {
            self.body = "\n\n\(sig)"
        }
    }

    // MARK: - Capabilities

    public var canSend: Bool { sendProvider != nil }
    public var canSaveDraft: Bool { draftSaver != nil }

    // MARK: - Validation

    /// Поле «To» должно содержать минимум один валидный e-mail.
    public var isToValid: Bool {
        !toTokens.isEmpty && toTokens.allSatisfy(Self.isValidEmail)
    }

    public var isCcValid: Bool {
        ccTokens.allSatisfy(Self.isValidEmail)
    }

    public var isBccValid: Bool {
        bccTokens.allSatisfy(Self.isValidEmail)
    }

    public var isFormValid: Bool {
        isToValid && isCcValid && isBccValid
    }

    /// Закрытие окна с непустым черновиком должно подтверждаться.
    public var hasUnsavedContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !toTokens.isEmpty
    }

    // MARK: - Parsing

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
            to: toTokens,
            cc: ccTokens,
            bcc: bccTokens
        )
        let mime = MIMEComposer.compose(
            from: fromHeader,
            recipients: MIMEComposer.Recipients(
                to: toTokens,
                cc: ccTokens,
                bcc: bccTokens
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
        guard isCcValid, isBccValid, toTokens.allSatisfy(Self.isValidEmail) else {
            draftState = .error("Проверьте поля получателей")
            return
        }
        draftState = .saving
        let envelope = DraftEnvelope(
            from: fromHeader,
            to: toTokens,
            cc: ccTokens,
            bcc: bccTokens,
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

    // MARK: - Factory methods (Reply / ReplyAll / Forward)

    /// Reply: заполняет поле To = from исходного письма, Subject = "Re: …",
    /// тело — цитата исходного письма. Если передана подпись — добавляется перед цитатой.
    public static func makeReply(
        to original: Message,
        accountEmail: String,
        accountDisplayName: String?,
        sendProvider: (any SendProvider)?,
        draftSaver: DraftSaver?,
        defaultSignatureBody: String? = nil
    ) -> ComposeViewModel {
        let vm = ComposeViewModel(
            accountEmail: accountEmail,
            accountDisplayName: accountDisplayName,
            sendProvider: sendProvider,
            draftSaver: draftSaver,
            defaultSignatureBody: defaultSignatureBody
        )
        if let fromAddress = original.from?.address, !fromAddress.isEmpty {
            vm.toTokens = [fromAddress]
        }
        vm.subject = Self.reSubject(original.subject)
        vm.body = vm.body + Self.quotedBody(original)
        return vm
    }

    /// ReplyAll: To = from исходного, Cc = все to + cc оригинала минус себя.
    public static func makeReplyAll(
        to original: Message,
        accountEmail: String,
        accountDisplayName: String?,
        sendProvider: (any SendProvider)?,
        draftSaver: DraftSaver?,
        defaultSignatureBody: String? = nil
    ) -> ComposeViewModel {
        let vm = ComposeViewModel(
            accountEmail: accountEmail,
            accountDisplayName: accountDisplayName,
            sendProvider: sendProvider,
            draftSaver: draftSaver,
            defaultSignatureBody: defaultSignatureBody
        )
        if let fromAddress = original.from?.address, !fromAddress.isEmpty {
            vm.toTokens = [fromAddress]
        }
        vm.ccTokens = (original.to + original.cc)
            .map(\.address)
            .filter { $0.lowercased() != accountEmail.lowercased() }
        vm.subject = Self.reSubject(original.subject)
        vm.body = vm.body + Self.quotedBody(original)
        return vm
    }

    /// Forward: To/Cc пусты, Subject = "Fwd: …", тело — цитата оригинала.
    public static func makeForward(
        of original: Message,
        accountEmail: String,
        accountDisplayName: String?,
        sendProvider: (any SendProvider)?,
        draftSaver: DraftSaver?,
        defaultSignatureBody: String? = nil
    ) -> ComposeViewModel {
        let vm = ComposeViewModel(
            accountEmail: accountEmail,
            accountDisplayName: accountDisplayName,
            sendProvider: sendProvider,
            draftSaver: draftSaver,
            defaultSignatureBody: defaultSignatureBody
        )
        vm.subject = Self.fwdSubject(original.subject)
        vm.body = vm.body + Self.quotedBody(original)
        return vm
    }

    // MARK: - Instance reply/forward initializers

    /// Применяет режим «Ответить» к текущему экземпляру ViewModel.
    public func reply(to original: Message) {
        if let fromAddress = original.from?.address, !fromAddress.isEmpty {
            toTokens = [fromAddress]
        }
        ccTokens = []
        bccTokens = []
        subject = Self.reSubject(original.subject)
        body = body + Self.quotedBody(original)
    }

    /// Применяет режим «Ответить всем» к текущему экземпляру ViewModel.
    public func replyAll(to original: Message) {
        if let fromAddress = original.from?.address, !fromAddress.isEmpty {
            toTokens = [fromAddress]
        }
        ccTokens = (original.to + original.cc)
            .map(\.address)
            .filter { $0.lowercased() != accountEmail.lowercased() }
        bccTokens = []
        subject = Self.reSubject(original.subject)
        body = body + Self.quotedBody(original)
    }

    /// Применяет режим «Переслать» к текущему экземпляру ViewModel.
    public func forward(message original: Message) {
        toTokens = []
        ccTokens = []
        bccTokens = []
        subject = Self.fwdSubject(original.subject)
        body = body + Self.quotedBody(original)
    }

    // MARK: - Quote helpers

    private static func reSubject(_ subject: String) -> String {
        subject.hasPrefix("Re:") ? subject : "Re: \(subject)"
    }

    private static func fwdSubject(_ subject: String) -> String {
        subject.hasPrefix("Fwd:") ? subject : "Fwd: \(subject)"
    }

    private static func quotedBody(_ message: Message) -> String {
        let dateStr = Self.quoteDate(message.date)
        let fromStr = message.from?.address ?? ""
        var quote = "\n\n— Пересланное сообщение —\nОт: \(fromStr)\nДата: \(dateStr)\nТема: \(message.subject)"
        if let preview = message.preview, !preview.isEmpty {
            quote += "\n\n\(preview)"
        }
        return quote
    }

    private static func quoteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Helpers

    private static func describe(_ err: MailError) -> String {
        err.errorDescription ?? "Не удалось выполнить операцию"
    }
}
