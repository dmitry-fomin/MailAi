# SwiftNIO (+ NIOSSL)

**Library ID (Context7)**: `/apple/swift-nio`, `/apple/swift-nio-ssl`
**Роль в проекте**: транспорт IMAP (модуль `MailTransport`).

## Назначение

Асинхронный event-driven сетевой фреймворк от Apple. Даёт TCP/TLS-каналы, pipeline handler'ов и (главное для нас) мост в Swift Concurrency через `NIOAsyncChannel`.

## Минимальный клиент (наш паттерн)

```swift
import NIOCore
import NIOPosix
import NIOSSL

let eventLoopGroup = MultiThreadedEventLoopGroup.singleton

let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())

let client = try await ClientBootstrap(group: eventLoopGroup)
    .connect(host: "imap.gmail.com", port: 993) { channel in
        channel.eventLoop.makeCompletedFuture {
            let sslHandler = try NIOSSLClientHandler(
                context: sslContext,
                serverHostname: "imap.gmail.com"
            )
            try channel.pipeline.syncOperations.addHandler(sslHandler)
            // line-framing для IMAP (CRLF-terminated)
            try channel.pipeline.syncOperations.addHandler(
                ByteToMessageHandler(LineBasedFrameDecoder())
            )
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: channel
            )
        }
    }

try await client.executeThenClose { inbound, outbound in
    try await outbound.write(ByteBuffer(string: "a001 LOGIN ...\r\n"))
    for try await line in inbound {
        // разбор IMAP-ответа
    }
}
```

## Ключевые API

- `MultiThreadedEventLoopGroup.singleton` — один EventLoop на процесс для клиентов, **не** создавать собственные без нужды.
- `ClientBootstrap.connect(host:port:channelInitializer:) async throws` — async-вариант, не возвращает `EventLoopFuture`.
- `NIOAsyncChannel<Inbound, Outbound>(wrappingChannelSynchronously:)` — мост в async/await. Inbound — `AsyncSequence`, outbound — `write(_:)`.
- `executeThenClose { inbound, outbound in ... }` — единственно правильный способ использовать `NIOAsyncChannel` (гарантирует закрытие).
- `channel.pipeline.syncOperations.addHandler(_:)` — внутри `makeCompletedFuture` блока, когда мы на event loop.
- `ByteToMessageHandler` + `LineBasedFrameDecoder` — фрейминг по `\n`. Для IMAP по `\r\n` подойдёт.

## NIOSSL

- `NIOSSLContext(configuration: .makeClientConfiguration())` — дефолтный клиент.
- `NIOSSLClientHandler(context:serverHostname:)` — обязательно `serverHostname` (SNI + verification).
- Certificate pinning — через `certificateVerification = .noHostnameVerification` + кастомный verify callback (**не** применяем к почтовым серверам, только к OpenRouter если решим).

## Частые ошибки

- **Создавать отдельный `MultiThreadedEventLoopGroup` на каждое соединение** — утечка потоков. Используем `.singleton`.
- **Вызывать `channel.pipeline.addHandler` вне event loop** — race. Либо `syncOperations` внутри init-колбэка, либо `.addHandler(...).wait()` во future chain.
- **Забывать `executeThenClose`** — канал не закрывается, утечка соединения.
- **Не ставить `serverHostname`** → TLS без проверки сертификата → MITM.
- **Читать из `inbound` без лимитов** → back-pressure ломается; используем `AsyncSequence.prefix(...)` или явное закрытие.
- **Mixing EventLoopFuture + async/await** в одном коде — работает, но путает. Держимся async/await API.

## Версии и совместимость

- SwiftNIO 2.x, async API от macOS 10.15+ (у нас macOS 14+ — всё доступно).
- `NIOAsyncChannel` — стабильный с NIO 2.59+.
- Strict Concurrency — NIO 2.60+ помечен `Sendable` корректно.

## Ссылки

- Docs: https://swiftpackageindex.com/apple/swift-nio/documentation
- Concurrency guide: https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/Docs.docc/swift-concurrency.md
