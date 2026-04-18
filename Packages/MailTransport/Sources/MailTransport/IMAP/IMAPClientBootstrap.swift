import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Конфигурация подключения к IMAP-серверу.
public struct IMAPEndpoint: Sendable, Equatable {
    public enum Security: Sendable, Equatable {
        /// Сразу TLS (implicit) — порт 993.
        case tls
        /// Без TLS — только для тестов через `EmbeddedChannel` или plain-серверов.
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

    public static func gmail() -> IMAPEndpoint {
        .init(host: "imap.gmail.com", port: 993, security: .tls)
    }

    public static func yandex() -> IMAPEndpoint {
        .init(host: "imap.yandex.com", port: 993, security: .tls)
    }
}

public enum IMAPBootstrapError: Error, Equatable, Sendable {
    case tlsContextCreationFailed
    case unexpectedChannelType
}

/// Фабрика IMAP-каналов поверх SwiftNIO. Выставляет `NIOAsyncChannel<IMAPLine, IMAPLine>`
/// — инбаунд и аутбаунд оба `IMAPLine`. Line-framing и TLS настраиваются в
/// `ChannelPipeline` внутри.
public enum IMAPClientBootstrap {

    /// Подключается к указанному endpoint. Возвращает `NIOAsyncChannel` и
    /// вызывающий должен обернуть работу в `executeThenClose { ... }`.
    public static func connect(
        to endpoint: IMAPEndpoint,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton,
        connectTimeout: TimeAmount = .seconds(10)
    ) async throws -> NIOAsyncChannel<IMAPLine, IMAPLine> {
        let sslContext: NIOSSLContext? = try {
            switch endpoint.security {
            case .plain: return nil
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
    /// Вызывается внутри `makeCompletedFuture` на event loop'е канала —
    /// безопасно для `syncOperations`.
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
        try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
        try sync.addHandler(IMAPLineFrameEncoder())
    }
}
