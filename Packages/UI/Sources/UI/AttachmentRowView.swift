import SwiftUI
import Core

/// Одна строка в списке вложений: имя файла, размер, кнопки Quick Look и Save As.
public struct AttachmentRowView: View {
    public let attachment: Attachment
    public var onQuickLook: () -> Void
    public var onSaveAs: () -> Void

    public init(
        attachment: Attachment,
        onQuickLook: @escaping () -> Void = {},
        onSaveAs: @escaping () -> Void = {}
    ) {
        self.attachment = attachment
        self.onQuickLook = onQuickLook
        self.onSaveAs = onSaveAs
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: attachment.mimeType))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename.isEmpty ? "Вложение" : attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(formattedSize(attachment.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onQuickLook) {
                Image(systemName: "eye")
                    .help("Быстрый просмотр")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Быстрый просмотр")

            Button(action: onSaveAs) {
                Image(systemName: "square.and.arrow.down")
                    .help("Сохранить как…")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Сохранить как…")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
    }

    // MARK: - Helpers

    private func formattedSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f КБ", max(1, kb))
        } else {
            let mb = kb / 1024
            return String(format: "%.1f МБ", mb)
        }
    }

    private func iconName(for mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return "photo" }
        if lower.hasPrefix("video/") { return "film" }
        if lower.hasPrefix("audio/") { return "music.note" }
        if lower.contains("pdf") { return "doc.richtext" }
        if lower.contains("zip") || lower.contains("archive") || lower.contains("gzip") {
            return "archivebox"
        }
        if lower.contains("text/") { return "doc.text" }
        return "paperclip"
    }
}
