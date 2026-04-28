import SwiftUI

/// Одна строка прикреплённого файла в окне Compose:
/// иконка, имя файла, размер и кнопка удаления.
struct ComposeAttachmentRow: View {
    let attachment: ComposeAttachment
    let onRemove: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: attachment.mimeType))
                .font(.system(size: 14))
                .foregroundStyle(iconColor(for: attachment.mimeType))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(formattedSize(attachment.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(isHovered ? .red : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Удалить вложение \(attachment.filename)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .onHover { hovering in isHovered = hovering }
    }

    // MARK: - Helpers

    private func formattedSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f КБ", max(1, kb))
        } else {
            return String(format: "%.1f МБ", kb / 1024)
        }
    }

    private func iconName(for mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return "photo" }
        if lower.hasPrefix("video/") { return "film" }
        if lower.hasPrefix("audio/") { return "music.note" }
        if lower.contains("pdf") { return "doc.richtext" }
        if lower.contains("zip") || lower.contains("archive") { return "archivebox" }
        if lower.contains("word") || lower.contains("msword") { return "doc.text" }
        if lower.contains("excel") || lower.contains("spreadsheet") { return "tablecells" }
        if lower.hasPrefix("text/") { return "doc.text" }
        return "paperclip"
    }

    private func iconColor(for mimeType: String) -> Color {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return .blue }
        if lower.hasPrefix("video/") { return .purple }
        if lower.hasPrefix("audio/") { return .pink }
        if lower.contains("pdf") { return .red }
        if lower.contains("zip") || lower.contains("archive") { return .orange }
        if lower.contains("excel") || lower.contains("spreadsheet") { return .green }
        return Color(nsColor: .secondaryLabelColor)
    }
}
