import Foundation
import NIOCore
import NIOPosix
import NIOSSL

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
}

/// Фабрика SMTP-каналов поверх SwiftNIO.
/// Для implicit TLS (порт 465) добавляет `NIOSSLClientHandler` сразу в pipeline.
/// Для STARTTLS (порт 587) — подключение в plain, TLS добавляется позже через
/// `performStartTLS(host:)` в `SMTPConnection`.
/// Переиспользует IMAPLine-декодер/энкодер — логика CRLF-framing идентична.
public enum SMTPClientBootstrap {

    /// Подключается к SMTP-серверу. Для `.tls` — сразу устанавливает TLS.
    /// Возвращает `NIOAsyncChannel<IMAPLine, IMAPLine>` — переиспользуем
    /// IMAPLine-фрейминг (CRLF line-framing идентичен для SMTP).
    public static func connect(
        to endpoint: SMTPEndpoint,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton,
        connectTimeout: TimeAmount = .seconds(10)
    ) async throws -> NIOAsyncChannel<IMAPLine, IMAPLine> {
        // SSL-контекст нужен для .tls (implicit) — будет добавлен сразу в pipeline.
        // Для .startTLS — TLS подключается позже через отдельный вызов.
        let sslContext: NIOSSLContext? = try {
            switch endpoint.security {
            case .plain, .startTLS: return nil
            case .tls:
                return try NIOSSLContext(configuration: .makeClientConfiguration())
            }
        }()

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(connectTimeout)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.connect(
            host: endpoint.host,
            port: endpoint.port
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try Self.configurePipeline(
                    channel: channel,
                    sslContext: sslContext,
                    serverHostname: endpoint.host
                )
                return try NIOAsyncChannel<IMAPLine, IMAPLine>(
                    wrappingChannelSynchronously: channel
                )
            }
        }
        return channel
    }

    /// Конфигурирует pipeline: (optional) NIOSSLClientHandler → ByteToMessageHandler(LineDecoder) → LineEncoder.
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
        // Оборачиваем IMAPLine ↔ String конвертацию на уровне SMTPConnection.
        try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
        try sync.addHandler(IMAPLineFrameEncoder())
    }
}
