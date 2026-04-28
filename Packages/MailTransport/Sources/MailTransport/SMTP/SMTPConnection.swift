import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Учётные данные для SMTP-аутентификации.
public struct SMTPCredentials: Sendable, Equatable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Высокоуровневая SMTP-сессия. Живёт строго внутри замыкания
/// `withOpen(...) { conn in ... }` — это соответствует
/// `NIOAsyncChannel.executeThenClose` scoping.
///
/// Инвариант последовательного доступа: все вызовы методов SMTPConnection
/// должны выполняться строго серийно в рамках одной Task (один writer/один reader).
/// Concurrent-доступ из нескольких Task — undefined behaviour.
/// @unchecked Sendable допустим при соблюдении этого инварианта.
public final class SMTPConnection: @unchecked Sendable {

    /// Канал — переиспользуем IMAPLine как тип фрейма (CRLF-framing идентичен).
    public typealias SMTPChannel = NIOAsyncChannel<IMAPLine, IMAPLine>

    // nonisolated(unsafe): доступ строго серийный — один вызов за раз в одной Task.
    // Мутация iterator происходит только внутри readResponse/readMultiLineResponse
    // которые вызываются последовательно в рамках withOpen-замыкания.
    nonisolated(unsafe) private var iterator: NIOAsyncChannelInboundStream<IMAPLine>.AsyncIterator
    private let outbound: NIOAsyncChannelOutboundWriter<IMAPLine>

    /// Расширения сервера из EHLO-ответа.
    /// Мутируется только последовательно в ehlo() — в рамках инварианта серийного доступа.
    nonisolated(unsafe) public private(set) var capabilities: Set<String> = []

    // MARK: - Открытие соединения

    /// Подключается к SMTP-серверу, выполняет EHLO, STARTTLS (если нужно),
    /// AUTH — и передаёт готовое соединение в замыкание.
    /// Канал гарантированно закрыт после выхода.
    ///
    /// Для `.startTLS` безопасный двухэтапный upgrade выполняется в
    /// `SMTPClientBootstrap.connect` ДО создания NIOAsyncChannel —
    /// TLS handler никогда не добавляется в активный канал (исправлен MailAi-7ac).
    public static func withOpen<R>(
        endpoint: SMTPEndpoint,
        credentials: SMTPCredentials,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton,
        connectTimeout: TimeAmount = .seconds(10),
        _ body: (SMTPConnection) async throws -> R
    ) async throws -> R {
        // 1. TCP + TLS/STARTTLS (bootstrap выполняет нужный upgrade заранее).
        let channel = try await SMTPClientBootstrap.connect(
            to: endpoint,
            eventLoopGroup: eventLoopGroup,
            connectTimeout: connectTimeout
        )

        return try await channel.executeThenClose { inbound, outbound in
            var iter = inbound.makeAsyncIterator()

            // Для .plain и .tls читаем greeting здесь (для .startTLS greeting уже
            // был прочитан в PlainSMTPNegotiator.negotiate() во время bootstrap).
            if endpoint.security != .startTLS {
                let greeting = try await readResponse(from: &iter)
                guard greeting.code == 220 else {
                    throw SMTPError.unexpectedResponse(greeting.text)
                }
            }

            let smtp = SMTPConnection(iterator: iter, outbound: outbound)

            // 2. EHLO — определяем расширения.
            // Для .startTLS bootstrap уже выполнил первый EHLO; после TLS upgrade
            // нужен повторный EHLO (сервер может опубликовать расширенный список).
            try await smtp.ehlo(hostname: endpoint.host)

            // 3. Аутентификация.
            try await smtp.authenticate(credentials: credentials)

            return try await body(smtp)
        }
    }

    fileprivate init(
        iterator: NIOAsyncChannelInboundStream<IMAPLine>.AsyncIterator,
        outbound: NIOAsyncChannelOutboundWriter<IMAPLine>
    ) {
        self.iterator = iterator
        self.outbound = outbound
    }

    // MARK: - EHLO

    /// Отправляет EHLO и собирает capabilities из многострочного ответа.
    private func ehlo(hostname: String) async throws {
        // Используем hostname как идентификатор клиента (RFC 5321 §4.1.1).
        // Если имя слишком длинное — обрезаем.
        let ehloName = String(hostname.prefix(255))
        try await sendCommand("EHLO \(ehloName)")
        let responses = try await readMultiLineResponse()

        guard let first = responses.first, first.code == 250 else {
            throw SMTPError.unexpectedResponse(
                responses.first.map { "\($0.code) \($0.text)" } ?? "пустой ответ"
            )
        }

        // Собираем capabilities из последующих строк (250-SIZE, 250-AUTH, и т.д.)
        var caps = Set<String>()
        for resp in responses.dropFirst() {
            // Каждый extension — первое слово в тексте строки
            let keyword = resp.text.split(separator: " ").first.map(String.init) ?? ""
            if !keyword.isEmpty {
                caps.insert(keyword.uppercased())
            }
        }
        // Первая строка EHLO тоже содержит домен сервера — не считаем capability.
        capabilities = caps
    }

    // MARK: - Аутентификация

    /// Выполняет аутентификацию, выбирая механизм на основе EHLO-расширений.
    /// Предпочитает AUTH PLAIN → AUTH LOGIN.
    private func authenticate(credentials: SMTPCredentials) async throws {
        // Проверяем наличие AUTH в capabilities.
        // Многие серверы возвращают "AUTH PLAIN LOGIN" как одну строку.
        let authLine = capabilities
            .first { $0.hasPrefix("AUTH") || $0 == "AUTH" }

        // Определяем, какие механизмы поддерживает сервер.
        // Упрощённая проверка: если capabilities содержат "AUTH" — поддерживается.
        // Реальные механизмы определяются текстом ответа EHLO.
        var supportsPlain = false
        var supportsLogin = false

        // Собираем полный текст EHLO для анализа AUTH-механизмов
        // (будет определено при повторном чтении ответов)
        // Для надёжности: пробуем PLAIN, затем LOGIN.
        if authLine != nil || capabilities.contains("AUTH") {
            // По умолчанию пробуем оба механизма.
            // Сервер сам отклонит неподдерживаемый.
            supportsPlain = true
            supportsLogin = true
        }

        // Предпочитаем AUTH PLAIN (один раунд).
        if supportsPlain {
            do {
                try await authPlain(credentials: credentials)
                return
            } catch SMTPError.authMethodNotSupported {
                // Метод PLAIN не поддерживается сервером (504/534) — пробуем LOGIN.
                // Ошибки authenticationFailed (535) и authentication НЕ перехватываем:
                // неверный пароль не исправить сменой механизма.
            }
        }

        if supportsLogin {
            try await authLogin(credentials: credentials)
            return
        }

        // Если ни один механизм не подходит — считаем, что аутентификация не нужна
        // (некоторые серверы принимают without auth после STARTTLS)
    }

    /// AUTH PLAIN: отправляет `\0username\0password` в base64 одной строкой.
    private func authPlain(credentials: SMTPCredentials) async throws {
        // RFC 4616: authzid\0authcid\0passwd
        let plain = "\0\(credentials.username)\0\(credentials.password)"
        let encoded = Data(plain.utf8).base64EncodedString()

        try await sendCommand("AUTH PLAIN \(encoded)")
        let resp = try await readResponse()

        switch resp.code {
        case 235:
            // Успех — аутентификация пройдена
            return
        case 334:
            // Сервер ждёт данные отдельно (не в команде) — отправляем
            try await sendCommand(encoded)
            let resp2 = try await readResponse()
            guard resp2.code == 235 else {
                throw SMTPError.authenticationFailed(resp2.text)
            }
        case 504, 534:
            // Метод не поддерживается сервером — можно попробовать другой механизм
            throw SMTPError.authMethodNotSupported("AUTH PLAIN не поддерживается: \(resp.code) \(resp.text)")
        case 535:
            // Неверные учётные данные — не имеет смысла пробовать другой механизм
            throw SMTPError.authenticationFailed("Неверные учётные данные (AUTH PLAIN): \(resp.text)")
        default:
            throw SMTPError.authMethodNotSupported("AUTH PLAIN отклонён: \(resp.code) \(resp.text)")
        }
    }

    /// AUTH LOGIN: отправляет username и password в base64 по очереди.
    private func authLogin(credentials: SMTPCredentials) async throws {
        try await sendCommand("AUTH LOGIN")

        // Сервер отправляет "334 <base64('Username:')>"
        let resp1 = try await readResponse()
        guard resp1.code == 334 else {
            throw SMTPError.authentication("AUTH LOGIN отклонён: \(resp1.code) \(resp1.text)")
        }

        // Отправляем username в base64
        let userEncoded = Data(credentials.username.utf8).base64EncodedString()
        try await sendCommand(userEncoded)

        // Сервер отправляет "334 <base64('Password:')>"
        let resp2 = try await readResponse()
        guard resp2.code == 334 else {
            throw SMTPError.authentication("AUTH LOGIN: неверное имя пользователя")
        }

        // Отправляем password в base64
        let passEncoded = Data(credentials.password.utf8).base64EncodedString()
        try await sendCommand(passEncoded)

        // Финальный ответ
        let resp3 = try await readResponse()
        guard resp3.code == 235 else {
            throw SMTPError.authentication("AUTH LOGIN: \(resp3.code) \(resp3.text)")
        }
    }

    // MARK: - Отправка письма

    /// Отправляет письмо: MAIL FROM → RCPT TO → DATA.
    /// - Parameters:
    ///   - from: Email-адрес отправителя (Envelope From).
    ///   - to: Массив адресов получателей.
    ///   - data: Готовое MIME-сообщение (RFC 5322), включая заголовки.
    public func send(from: String, to: [String], data: String) async throws {
        guard !from.isEmpty else {
            throw SMTPError.unexpectedResponse("Пустой адрес отправителя")
        }
        guard !to.isEmpty else {
            throw SMTPError.unexpectedResponse("Пустой список получателей")
        }

        // MAIL FROM
        try await sendCommand("MAIL FROM:<\(from)>")
        let mailResp = try await readResponse()
        guard mailResp.code == 250 else {
            throw SMTPError.relay(mailResp.code, mailResp.text)
        }

        // RCPT TO — для каждого получателя
        for recipient in to {
            try await sendCommand("RCPT TO:<\(recipient)>")
            let rcptResp = try await readResponse()
            guard rcptResp.code == 250 else {
                throw SMTPError.relay(rcptResp.code, "Получатель \(recipient): \(rcptResp.text)")
            }
        }

        // DATA — передаём тело сообщения
        try await sendCommand("DATA")
        let dataResp = try await readResponse()
        guard dataResp.code == 354 else {
            throw SMTPError.unexpectedCode(dataResp.code, dataResp.text)
        }

        // Тело письма: точка на отдельной строке = конец (RFC 5321 §4.1.1.4).
        // Дублируем точки в начале строк (dot-stuffing).
        // Сначала нормализуем переносы: одиночный \n → \r\n, чтобы dot-stuffing
        // корректно обрабатывал все строки (RFC 5321 требует CRLF).
        let normalized = data
            .replacingOccurrences(of: "\r\n", with: "\n")   // сводим к \n
            .replacingOccurrences(of: "\n", with: "\r\n")   // нормализуем в \r\n
        let stuffed = normalized
            .components(separatedBy: "\r\n")
            .map { line in
                line.hasPrefix(".") ? ".\(line)" : line
            }
            .joined(separator: "\r\n")

        // Финальный маркер DATA: точка на отдельной строке с CRLF до и после (RFC 5321 §4.5.2).
        // Формат: <тело>\r\n.\r\n  — точка именно на отдельной строке.
        try await sendCommand("\(stuffed)\r\n.")
        let endResp = try await readResponse()
        guard endResp.code == 250 else {
            throw SMTPError.relay(endResp.code, endResp.text)
        }
    }

    // MARK: - QUIT

    /// Корректно завершает SMTP-сессию командой QUIT.
    public func quit() async throws {
        _ = try? await sendAndRead("QUIT")
    }

    // MARK: - Низкоуровневый IO

    /// Отправляет команду (добавляет CRLF).
    private func sendCommand(_ command: String) async throws {
        try await outbound.write(IMAPLine(command))
    }

    /// Читает одну строку ответа и парсит её.
    private func readResponse() async throws -> SMTPResponse {
        try await Self.readResponse(from: &iterator)
    }

    /// Читает многострочный SMTP-ответ (все строки до нефинальной с code + space).
    private func readMultiLineResponse() async throws -> [SMTPResponse] {
        var responses: [SMTPResponse] = []
        while let line = try await iterator.next() {
            guard let resp = SMTPResponse.parse(line.raw) else {
                throw SMTPError.unexpectedResponse(line.raw)
            }
            responses.append(resp)
            if !resp.isContinuation { break }
        }
        guard !responses.isEmpty else {
            throw SMTPError.channelClosed
        }
        return responses
    }

    /// Отправляет команду и читает один ответ.
    private func sendAndRead(_ command: String) async throws -> SMTPResponse {
        try await sendCommand(command)
        return try await readResponse()
    }

    /// Статический помощник для чтения ответа (используется до создания SMTPConnection).
    private static func readResponse(
        from iterator: inout NIOAsyncChannelInboundStream<IMAPLine>.AsyncIterator
    ) async throws -> SMTPResponse {
        guard let line = try await iterator.next() else {
            throw SMTPError.channelClosed
        }
        guard let resp = SMTPResponse.parse(line.raw) else {
            throw SMTPError.unexpectedResponse(line.raw)
        }
        return resp
    }
}
