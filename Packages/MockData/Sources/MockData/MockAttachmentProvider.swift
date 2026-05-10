import Foundation
import Core

/// Фиктивный провайдер вложений для dev-режима и превью.
/// Возвращает несколько байт тестовых данных вместо реального контента вложения.
public actor MockAttachmentProvider: AttachmentProvider {
    public init() {}

    public func attachmentStream(
        for attachment: Attachment,
        messageID: Message.ID
    ) -> AsyncThrowingStream<Data, any Error> {
        let filename = attachment.filename
        let fakePayload = Data("Mock attachment data for \(filename) (messageID: \(messageID.rawValue))".utf8)
        return AsyncThrowingStream { continuation in
            continuation.yield(fakePayload)
            continuation.finish()
        }
    }
}
