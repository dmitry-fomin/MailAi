import SwiftUI
import Core

/// Одна строка в списке вложений: иконка типа файла, имя, размер,
/// кнопки Quick Look, Save As и (для поддерживаемых форматов) AI Summarize.
public struct AttachmentRowView: View {
    public let attachment: Attachment
    public var onQuickLook: () -> Void
    public var onSaveAs: () -> Void
    /// Суммаризация вложения через AI. nil — кнопка не показывается.
    /// Показывается только для PDF, DOCX, TXT, RTF.
    public var onSummarize: (() -> Void)?

    @State private var isHovered: Bool = false

    public init(
        attachment: Attachment,
        onQuickLook: @escaping () -> Void = {},
        onSaveAs: @escaping () -> Void = {},
        onSummarize: (() -> Void)? = nil
    ) {
        self.attachment = attachment
        self.onQuickLook = onQuickLook
        self.onSaveAs = onSaveAs
        self.onSummarize = onSummarize
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: attachment.mimeType))
                .font(.system(size: 16))
                .foregroundStyle(iconColor(for: attachment.mimeType))
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
                    .help("Быстрый просмотр (пробел)")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Быстрый просмотр")

            Button(action: onSaveAs) {
                Image(systemName: "square.and.arrow.down")
                    .help("Сохранить как…")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Сохранить как…")

            if let onSummarize, canSummarize(mimeType: attachment.mimeType) {
                Button(action: onSummarize) {
                    Image(systemName: "sparkles")
                        .help("Суммаризовать (AI)")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Суммаризовать через AI")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered
                    ? Color(nsColor: .tertiaryLabelColor).opacity(0.4)
                    : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .onHover { hovering in isHovered = hovering }
        .onTapGesture(count: 2) { onQuickLook() }
        .onTapGesture(count: 1) { onQuickLook() }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Быстрый просмотр") { onQuickLook() }
        .accessibilityAction(named: "Сохранить как…") { onSaveAs() }
    }

    // MARK: - Helpers

    private func canSummarize(mimeType: String) -> Bool {
        let lower = mimeType.lowercased()
        return lower.contains("pdf")
            || lower.hasPrefix("text/")
            || lower.contains("rtf")
            || lower.contains("word")
            || lower.contains("msword")
            || lower.contains("openxmlformats-officedocument.wordprocessingml")
    }

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
        if lower.contains("word") || lower.contains("msword") { return "doc.text" }
        if lower.contains("excel") || lower.contains("spreadsheet") { return "tablecells" }
        if lower.contains("presentation") || lower.contains("powerpoint") { return "rectangle.on.rectangle" }
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
        if lower.contains("word") || lower.contains("msword") { return .blue }
        return Color(nsColor: .secondaryLabelColor)
    }
}
