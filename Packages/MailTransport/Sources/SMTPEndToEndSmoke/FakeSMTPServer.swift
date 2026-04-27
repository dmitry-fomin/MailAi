// SMTP-6: in-process fake SMTP server на SwiftNIO.
//
// Минимальная реализация RFC 5321: greeting → EHLO → AUTH PLAIN → MAIL FROM →
// RCPT TO → DATA → QUIT. Поддерживает CRLF-framing через `IMAPLineFrameDecoder/Encoder`,
// который переиспользует SMTPConnection.
//
// Сценарии задаются `Behavior`:
//   - .acceptAll — happy-path, отвечает 250 на все команды.
//   - .rejectRecipient(reason:) — отвечает 550 на RCPT TO.
//
// После завершения сессии хранит последний полученный envelope и raw DATA.
// Тела писем не пишутся в лог — только во внутренний буфер для проверки.

import Foundation
import NIOCore
import NIOPosix
import MailTransport

/// Поведение fake SMTP-сервера.
enum FakeSMTPBehavior: Sendable {
    /// Happy-path: все команды принимаются.
    case acceptAll
    /// Отказ на RCPT TO: код 550, заданный текст.
    case rejectRecipient(reason: String)
}

/// Снимок завершённой SMTP-сессии для assertion-ов.
struct FakeSMTPCapture: Sendable {
    let mailFrom: String?
    let rcptTo: [String]
    let dataBlock: String
    let ehloSeen: Bool
    let authPlainSeen: Bool
    let quitSeen: Bool
}

/// Потокобезопасное хранилище последнего capture (актор).
actor FakeSMTPCaptureStore {
    private(set) var last: FakeSMTPCapture?

    func set(_ capture: FakeSMTPCapture) {
        self.last = capture
    }
}

/// ChannelInboundHandler — реализует state-machine SMTP-сессии.
final class FakeSMTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = IMAPLine
    typealias OutboundOut = IMAPLine

    private enum Phase {
        case greeting
        case afterEhlo
        case afterAuth
        case afterMail
        case afterRcpt
        case readingData
        case done
    }

    private let behavior: FakeSMTPBehavior
    private let store: FakeSMTPCaptureStore

    private var phase: Phase = .greeting
    private var mailFrom: String?
    private var rcptTo: [String] = []
    private var dataLines: [String] = []
    private var ehloSeen = false
    private var authSeen = false
    private var quitSeen = false

    init(behavior: FakeSMTPBehavior, store: FakeSMTPCaptureStore) {
        self.behavior = behavior
        self.store = store
    }

    func channelActive(context: ChannelHandlerContext) {
        write(context, "220 fake-smtp.local ESMTP ready")
        context.flush()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data).raw

        if phase == .readingData {
            if line == "." {
                // Конец DATA-блока (RFC 5321 §4.1.1.4: точка на отдельной строке).
                phase = .afterAuth // принимаем следующее письмо/QUIT
                let rawData = dataLines.joined(separator: "\r\n")
                let capture = FakeSMTPCapture(
                    mailFrom: mailFrom,
                    rcptTo: rcptTo,
                    dataBlock: rawData,
                    ehloSeen: ehloSeen,
                    authPlainSeen: authSeen,
                    quitSeen: quitSeen
                )
                let store = self.store
                Task { await store.set(capture) }
                write(context, "250 OK: queued as fake-1")
                context.flush()
                return
            }
            // Dot-stuffing: ведущая `.` была удвоена клиентом.
            let unstuffed = line.hasPrefix("..") ? String(line.dropFirst()) : line
            dataLines.append(unstuffed)
            return
        }

        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") || upper.hasPrefix("HELO") {
            ehloSeen = true
            phase = .afterEhlo
            // Многострочный 250-ответ. AUTH PLAIN объявляем как поддерживаемый.
            write(context, "250-fake-smtp.local greets you")
            write(context, "250-SIZE 10240000")
            write(context, "250-AUTH PLAIN LOGIN")
            write(context, "250 HELP")
            context.flush()
            return
        }
        if upper.hasPrefix("AUTH PLAIN") {
            authSeen = true
            phase = .afterAuth
            write(context, "235 2.7.0 Authentication successful")
            context.flush()
            return
        }
        if upper.hasPrefix("MAIL FROM:") {
            mailFrom = Self.extractAngle(line)
            phase = .afterMail
            write(context, "250 2.1.0 Sender OK")
            context.flush()
            return
        }
        if upper.hasPrefix("RCPT TO:") {
            let addr = Self.extractAngle(line) ?? ""
            switch behavior {
            case .acceptAll:
                rcptTo.append(addr)
                phase = .afterRcpt
                write(context, "250 2.1.5 Recipient OK")
            case .rejectRecipient(let reason):
                write(context, "550 5.1.1 \(reason)")
            }
            context.flush()
            return
        }
        if upper == "DATA" {
            phase = .readingData
            write(context, "354 End data with <CR><LF>.<CR><LF>")
            context.flush()
            return
        }
        if upper.hasPrefix("QUIT") {
            quitSeen = true
            phase = .done
            // Если ещё не было DATA — фиксируем capture для failure-сценариев.
            let store = self.store
            let snapshot = FakeSMTPCapture(
                mailFrom: mailFrom,
                rcptTo: rcptTo,
                dataBlock: dataLines.joined(separator: "\r\n"),
                ehloSeen: ehloSeen,
                authPlainSeen: authSeen,
                quitSeen: true
            )
            Task { await store.set(snapshot) }
            write(context, "221 2.0.0 Bye")
            context.flush()
            context.close(promise: nil)
            return
        }
        if upper.hasPrefix("RSET") {
            phase = .afterAuth
            write(context, "250 OK")
            context.flush()
            return
        }
        // Неизвестная команда
        write(context, "500 5.5.1 Command unrecognized")
        context.flush()
    }

    private func write(_ context: ChannelHandlerContext, _ line: String) {
        context.write(wrapOutboundOut(IMAPLine(line)), promise: nil)
    }

    /// Извлекает адрес из `MAIL FROM:<addr>` / `RCPT TO:<addr>`.
    private static func extractAngle(_ line: String) -> String? {
        guard let lt = line.firstIndex(of: "<"),
              let gt = line.firstIndex(of: ">"),
              lt < gt else { return nil }
        return String(line[line.index(after: lt)..<gt])
    }
}

/// Локальный SMTP-сервер на 127.0.0.1, ephemeral port.
actor FakeSMTPServer {
    nonisolated let port: Int
    nonisolated let captureStore: FakeSMTPCaptureStore
    private let channel: any Channel

    static func start(
        on group: MultiThreadedEventLoopGroup,
        behavior: FakeSMTPBehavior
    ) async throws -> FakeSMTPServer {
        let store = FakeSMTPCaptureStore()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(ByteToMessageHandler(IMAPLineFrameDecoder()))
                    try sync.addHandler(IMAPLineFrameEncoder())
                    try sync.addHandler(FakeSMTPHandler(behavior: behavior, store: store))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = ch.localAddress?.port else {
            throw FakeServerError.noPort
        }
        return FakeSMTPServer(port: port, channel: ch, captureStore: store)
    }

    private init(port: Int, channel: any Channel, captureStore: FakeSMTPCaptureStore) {
        self.port = port
        self.channel = channel
        self.captureStore = captureStore
    }

    func stop() async throws {
        try await channel.close()
    }
}

enum FakeServerError: Error, Sendable {
    case noPort
}
