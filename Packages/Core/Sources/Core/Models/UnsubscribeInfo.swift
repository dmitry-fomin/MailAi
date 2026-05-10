import Foundation

/// Тип действия отписки, обнаруженный в заголовках письма.
public enum UnsubscribeAction: Sendable, Equatable {
    /// RFC 8058: одиночный HTTP POST-запрос.
    case oneClickPost(URL)
    /// Mailto-адрес для отправки запроса на отписку.
    case mailto(String)
    /// Ссылка в браузере (https:).
    case browserLink(URL)
    /// Заголовок List-Unsubscribe не найден или не распознан.
    case notFound
}

/// Информация об отписке, извлечённая из метаданных письма.
public struct UnsubscribeInfo: Sendable {
    public let action: UnsubscribeAction
    public let detectedFrom: DetectionSource

    public enum DetectionSource: Sendable {
        /// Определено из заголовка List-Unsubscribe.
        case listHeader
        /// Определено AI-анализом (резерв для будущего).
        case aiDetected
    }

    public init(action: UnsubscribeAction, detectedFrom: DetectionSource) {
        self.action = action
        self.detectedFrom = detectedFrom
    }
}
