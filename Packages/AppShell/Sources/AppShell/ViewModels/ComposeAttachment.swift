import Foundation

/// Файл, прикреплённый к исходящему письму в окне Compose.
/// Данные хранятся только в памяти — никогда не пишутся на диск дополнительно.
public struct ComposeAttachment: Identifiable, Sendable {
    public let id: UUID
    /// Исходный URL файла (для отображения имени и типа).
    public let url: URL
    /// Имя файла (последний компонент пути).
    public let filename: String
    /// MIME-тип, определённый по расширению.
    public let mimeType: String
    /// Бинарное содержимое файла в памяти.
    public let data: Data
    /// Размер в байтах.
    public var size: Int { data.count }

    public init(url: URL, filename: String, mimeType: String, data: Data) {
        self.id = UUID()
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
