import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

/// Конфигурация подключения к SMTP-серверу.
public struct SMTPEndpoint: Sendable, Equatable {
    /// Режим безопасности SMTP-подключения.
    public enum Security: Sendable, Equatable {
        /// Implicit TLS — TLS-рукопожатие сразу после подключения (порт 465).
        case tls
        /// STARTTLS — подключение в plain, затем_upgrade до TLS через команду STARTTLS (порт 587).
        case startTLS
        /// Без шифрования — только для локальных тестов.
        case plain
    }

    public let host: String
    public let port: Int
    public let security: Security

    public init(host: String, port: Int, security: Security) {
        self.host = host
        self.port = port
        self.security = security
    }

    /// Gmail SMTP через STARTTLS (порт 587).
    public static func gmail() -> SMTPEndpoint {
        .init(host: "smtp.gmail.com", port: 587, security: .startTLS)
    }

    /// Gmail SMTP через implicit TLS (порт 465).
    public static func gmailTLS() -> SMTPEndpoint {
        .init(host: "smtp.gmail.com", port: 465, security: .tls)
    }

    /// Yandex SMTP через STARTTLS (порт 587).
    public static func yandex() -> SMTPEndpoint {
        .init(host: "smtp.yandex.com", port: 587, security: .startTLS)
    }

    /// Yandex SMTP через implicit TLS (порт 465).
    public static func yandexTLS() -> SMTPEndpoint {
        .init(host: "smtp.yandex.com", port: 465, security: .tls)
    }
}

public enum SMTPBootstrapError: Error, Equatable, Sendable {
    case tlsContextCreationFailed
    case unexpectedChannelType
    /// Сервер не вернул ожидаемый greeting (220) до STARTTLS-upgrade.
    case unexpectedGreeting(String)
    /// Сервер отклонил STARTTLS до TLS-upgrade.
    case startTLSRejected(String)
    /// Сервер не объявил поддержку STARTTLS в EHLO.
    case startTLSNotAdvertised
}

/// Фабрика SMTP-каналов поверх SwiftNIO.
///
/// Поддерживает три режима:
/// - `.plain` — plain TCP без шифрования (тесты).
/// - `.tls` — implicit TLS (порт 465): TLS добавляется сразу в pipeline при connect.
/// - `.startTLS` — двухэтапный upgrade (порт 587):
///   1. Plain TCP-подключение, pipeline без NIOAsyncChannel wrapper.
///   2. Handshake EHLO + STARTTLS на уровне raw ByteBuffer.
///   3. Добавление `NIOSSLClientHandler` (безопасно — AsyncIterator ещё не создан).
///   4. Оборачивание в `NIOAsyncChannel` поверх уже-TLS-канала.
///
/// Это гарантирует, что TLS handler никогда не добавляется в pipeline активного
/// NIOAsyncChannel, устраняя архитектурный баг MailAi-7ac.
public enum SMTPClientBootstrap {

    // MARK: - Public API

    /// Подключается к SMTP-серверу. Возвращает `NIOAsyncChannel<IMAPLine, IMAPLine>`.
    ///
    /// Для `.startTLS` выполняет двухэтапный bootstrap:
    /// сначала plain, затем безопасный TLS upgrade до создания AsyncChannel.
    public static func connect(
        to endpoint: SMTPEndpoint,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton,
        connectTimeout: TimeAmount = .seconds(10)
    ) async throws -> NIOAsyncChannel<IMAPLine, IMAPLine> {
        switch endpoint.security {
        case .plain:
            return try await connectPlain(
                to: endpoint,
                eventLoopGroup: eventLoopGroup,
                connectTimeout: connectTimeout
            )
        case .tls:
            return try await connectImplicitTLS(
                to: endpoint,
                eventLoopGroup: eventLoopGroup,
                connectTimeout: connectTimeout
            )
        case .startTLS:
            return try await connectSTARTTLS(
                to: endpoint,
                eventLoopGroup: eventLoopGroup,
                connectTimeout: connectTimeout
            )
        }
    }

    // MARK: - Plain / Implicit TLS

    /// Plain TCP или implicit TLS — pipeline настраивается синхронно в bootstrap closure.
    private static func connectPlain(
        to endpoint: SMTPEndpoint,
        eventLoopGroup: MultiThreadedEventLoopGroup,
        connectTimeout: TimeAmount
    ) async throws -> NIOAsyncChannel<IMAPLine, IMAPLine> {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(connectTimeout)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)

        return try await bootstrap.connect(host: endpoint.host, port: endpoint.port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try Self.addLineFramingHandlers(to: channel)
                return try NIOAsyncChannel<IMAPLine, IMAPLine>(wrappingChannelSynchronously: channel)
            }
        }
    }

    private static func connectImplicitTLS(
        to endpoint: SMTPEndpoint,
        eventLoopGroup: MultiThreadedEventLoopGroup,
        connectTimeout: TimeAmount
    ) async throws -> NIOAsyncChannel<IMAPLine, IMAPLine> {
        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(connectTimeout)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)

        return try await bootstrap.connect(host: endpoint.host, port: endpoint.port) { channel in
            channel.eventLoop.makeCompletedFuture {
                let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: endpoint.host)
                try channel.pipeline.syncOperations.addHandler(tls)
                try Self.addLineFramingHandlers(to: channel)
                return try NIOAsyncChannel<IMAPLine, IMAPLine>(wrappingChannelSynchronously: channel)
            }
        }
    }

    // MARK: - STARTTLS (двухэтапный bootstrap)

    /// Двухэтапный STARTTLS:
    /// 1. Plain TCP-подключение с line-framing, БЕЗ NIOAsyncChannel wrapper.
    /// 2. Greeting + EHLO + STARTTLS через PlainSMTPNegotiator (ChannelHandler).
    /// 3. Добавление NIOSSLClientHandler (безопасно — NIOAsyncChannel ещё не создан).
    /// 4. Оборачивание в NIOAsyncChannel поверх уже-TLS-канала.
    ///
    /// Это гарантирует, что TLS handler добавляется ДО создания NIOAsyncChannel,
    /// исключая небезопасный addHandler в pipeline активного AsyncChannel (MailAi-7ac).
    private static func connectSTARTTLS(
        to endpoint: SMTPEndpoint,
        eventLoopGroup: MultiThreadedEventLoopGroup,
        connectTimeout: TimeAmount
    ) async throws -> NIOAsyncChannel<IMAPLine, IMAPLine> {
        let negotiator = PlainSMTPNegotiator(hostname: endpoint.host)

        // Шаг 1: plain-подключение. channelInitializer добавляет line-framing + negotiator.
        // connect(host:port:) → EventLoopFuture<Channel> — возвращает raw Channel, не NIOAsyncChannel.
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(connectTimeout)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.addLineFramingHandlers(to: channel)
                    try channel.pipeline.syncOperations.addHandler(negotiator)
                }
            }

        let plainChannel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()

        // Шаг 2: ждём завершения STARTTLS-диалога (Greeting → EHLO → STARTTLS 220).
        try await negotiator.negotiate()

        // Шаги 3-4 выполняются на event loop одним блоком: TLS handler не пересекает
        // Sendable-границу (NIOSSLClientHandler не Sendable), а NIOAsyncChannel создаётся
        // сразу после установки TLS — нет активного AsyncIterator, безопасно.
        let host = endpoint.host
        return try await plainChannel.eventLoop.submit {
            let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
            let tlsHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
            try plainChannel.pipeline.syncOperations.addHandler(tlsHandler, position: .first)
            return try NIOAsyncChannel<IMAPLine, IMAPLine>(wrappingChannelSynchronously: plainChannel)
        }.get()
    }

    // MARK: - Pipeline helpers

    /// Добавляет line-framing handlers (decoder + encoder). Вызывается синхронно
    /// внутри bootstrap closure или на event loop через makeCompletedFuture.
    static func addLineFramingHandlers(to channel: any Channel) throws {
        let sync = channel.pipeline.syncOperations
        try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
        try sync.addHandler(IMAPLineFrameEncoder())
    }

    // MARK: - Legacy pipeline configurator (совместимость)

    /// Конфигурирует pipeline: (optional) NIOSSLClientHandler → ByteToMessageHandler → LineEncoder.
    /// Используется только для `.plain` и `.tls` режимов (синхронная конфигурация при connect).
    public static func configurePipeline(
        channel: any Channel,
        sslContext: NIOSSLContext?,
        serverHostname: String
    ) throws {
        let sync = channel.pipeline.syncOperations
        if let sslContext {
            let tls = try NIOSSLClientHandler(
                context: sslContext,
                serverHostname: serverHostname
            )
            try sync.addHandler(tls)
        }
        // Переиспользуем IMAP-декодер/энкодер — логика CRLF-framing идентична.
        try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
        try sync.addHandler(IMAPLineFrameEncoder())
    }
}

// MARK: - PlainSMTPNegotiator

/// ChannelInboundHandler для plain SMTP-диалога до TLS-upgrade.
/// Перехватывает входящие `IMAPLine` (декодированные line-framing handler'ом),
/// разбирает SMTP-ответы и отправляет команды EHLO/STARTTLS.
///
/// Жизненный цикл: добавляется → negotiate() → остаётся в pipeline до TLS-upgrade.
/// NIOAsyncChannel создаётся только после того, как negotiate() завершился успешно
/// и TLS handler добавлен — это исключает небезопасный addHandler в активный канал.
final class PlainSMTPNegotiator: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = IMAPLine
    typealias InboundOut = IMAPLine

    private let hostname: String
    // Continuation для пробрасывания результата из NIO event loop в async контекст.
    nonisolated(unsafe) private var continuation: CheckedContinuation<Void, any Error>?
    // Буфер входящих строк до начала negotiate().
    nonisolated(unsafe) private var lineBuffer: [String] = []
    // Флаг: negotiate() уже ожидает строки.
    nonisolated(unsafe) private var isWaiting = false
    nonisolated(unsafe) private var pendingContinuation: CheckedContinuation<String, any Error>?
    nonisolated(unsafe) weak var context: ChannelHandlerContext?

    init(hostname: String) {
        self.hostname = hostname
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        let raw = line.raw

        if let pending = pendingContinuation {
            pendingContinuation = nil
            pending.resume(returning: raw)
        } else {
            lineBuffer.append(raw)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        pendingContinuation?.resume(throwing: error)
        pendingContinuation = nil
        continuation?.resume(throwing: error)
        continuation = nil
        context.fireErrorCaught(error)
    }

    // MARK: - Async API

    /// Ожидает следующую строку от сервера.
    private func readLine() async throws -> String {
        if !lineBuffer.isEmpty {
            return lineBuffer.removeFirst()
        }
        return try await withCheckedThrowingContinuation { cont in
            self.pendingContinuation = cont
        }
    }

    /// Отправляет SMTP-команду (добавляет CRLF через IMAPLine encoder).
    private func sendCommand(_ command: String) throws {
        guard let ctx = context else {
            throw SMTPError.channelClosed
        }
        let line = IMAPLine(command)
        ctx.writeAndFlush(NIOAny(line), promise: nil)
    }

    /// Читает одну строку и парсит SMTP-ответ.
    private func readResponse() async throws -> SMTPResponse {
        let raw = try await readLine()
        guard let resp = SMTPResponse.parse(raw) else {
            throw SMTPError.unexpectedResponse(raw)
        }
        return resp
    }

    /// Читает многострочный SMTP-ответ (все строки с кодом + дефис = continuation).
    private func readMultiLineResponse() async throws -> [SMTPResponse] {
        var responses: [SMTPResponse] = []
        repeat {
            let resp = try await readResponse()
            responses.append(resp)
            if !resp.isContinuation { break }
        } while true
        guard !responses.isEmpty else {
            throw SMTPError.channelClosed
        }
        return responses
    }

    /// Основной STARTTLS-диалог:
    /// 1. Читает greeting (220).
    /// 2. Отправляет EHLO, читает capability list.
    /// 3. Проверяет наличие STARTTLS.
    /// 4. Отправляет STARTTLS, читает 220.
    /// После успеха — pipeline готов к добавлению NIOSSLClientHandler.
    func negotiate() async throws {
        // 1. Greeting
        let greeting = try await readResponse()
        guard greeting.code == 220 else {
            throw SMTPBootstrapError.unexpectedGreeting("\(greeting.code) \(greeting.text)")
        }

        // 2. EHLO
        try sendCommand("EHLO \(String(hostname.prefix(255)))")
        let ehloLines = try await readMultiLineResponse()
        guard let first = ehloLines.first, first.code == 250 else {
            throw SMTPError.unexpectedResponse(
                ehloLines.first.map { "\($0.code) \($0.text)" } ?? "пустой ответ EHLO"
            )
        }

        // 3. Проверяем STARTTLS в capabilities
        let caps = Set(ehloLines.dropFirst().compactMap { resp -> String? in
            let kw = resp.text.split(separator: " ").first.map(String.init) ?? ""
            return kw.isEmpty ? nil : kw.uppercased()
        })
        guard caps.contains("STARTTLS") else {
            throw SMTPBootstrapError.startTLSNotAdvertised
        }

        // 4. STARTTLS
        try sendCommand("STARTTLS")
        let startResp = try await readResponse()
        guard startResp.code == 220 else {
            throw SMTPBootstrapError.startTLSRejected("\(startResp.code) \(startResp.text)")
        }
        // Успех — вызывающий снимает этот handler и добавляет NIOSSLClientHandler.
    }
}
