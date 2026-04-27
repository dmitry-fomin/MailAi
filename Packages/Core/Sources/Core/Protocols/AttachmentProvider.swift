import Foundation

/// Протокол для стриминга бинарного содержимого вложений.
/// Реализация никогда не кеширует данные на диске — только в памяти на время стрима.
public protocol AttachmentProvider: Actor {
    /// Стрим данных вложения по чанкам. Стрим закрывается после передачи
    /// всех байт или при отмене задачи вызывающей стороной.
    func attachmentStream(
        for attachment: Attachment,
        messageID: Message.ID
    ) -> AsyncThrowingStream<Data, any Error>
}
