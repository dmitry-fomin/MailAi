import SwiftUI
import Core

/// Секция вложений внизу письма. Если вложений нет — не рендерится.
/// Inline-изображения показываются как thumbnail; клик открывает Quick Look.
/// Остальные вложения — строки AttachmentRowView с иконкой, именем, размером и кнопками.
public struct AttachmentListView: View {
    public let attachments: [Attachment]
    /// Колбек Quick Look: вызывающая сторона должна загрузить данные и открыть QLPreviewPanel.
    public var onQuickLook: (Attachment) -> Void
    /// Колбек Save As: вызывающая сторона загружает данные и открывает NSSavePanel через AttachmentSaver.
    public var onSaveAs: (Attachment) -> Void
    /// Данные уже загруженных изображений для inline-превью (ключ — Attachment.ID).
    public var inlineImageData: [Attachment.ID: Data]

    public init(
        attachments: [Attachment],
        inlineImageData: [Attachment.ID: Data] = [:],
        onQuickLook: @escaping (Attachment) -> Void = { _ in },
        onSaveAs: @escaping (Attachment) -> Void = { _ in }
    ) {
        self.attachments = attachments
        self.inlineImageData = inlineImageData
        self.onQuickLook = onQuickLook
        self.onSaveAs = onSaveAs
    }

    // Разделяем вложения на inline-изображения и обычные
    private var inlineImages: [Attachment] {
        attachments.filter { att in
            att.isInline && att.mimeType.lowercased().hasPrefix("image/")
        }
    }

    private var regularAttachments: [Attachment] {
        attachments.filter { att in
            !(att.isInline && att.mimeType.lowercased().hasPrefix("image/"))
        }
    }

    public var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Inline-изображения как горизонтальный скролл миниатюр
                if !inlineImages.isEmpty {
                    inlineImagesSection
                }

                // Обычные вложения
                if !regularAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !inlineImages.isEmpty {
                            Text("Вложения (\(regularAttachments.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Вложения (\(regularAttachments.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(regularAttachments) { att in
                            AttachmentRowView(
                                attachment: att,
                                onQuickLook: { onQuickLook(att) },
                                onSaveAs: { onSaveAs(att) }
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Inline images section

    @ViewBuilder
    private var inlineImagesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Изображения (\(inlineImages.count))")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(inlineImages) { att in
                        InlineImageThumbnail(
                            attachment: att,
                            imageData: inlineImageData[att.id],
                            onTap: { onQuickLook(att) },
                            onSave: { onSaveAs(att) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Inline thumbnail

/// Миниатюра inline-изображения с кнопкой Сохранить.
private struct InlineImageThumbnail: View {
    let attachment: Attachment
    let imageData: Data?
    let onTap: () -> Void
    let onSave: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailImage
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .onTapGesture { onTap() }

            if isHovered {
                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(4)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(attachment.filename.isEmpty ? "Изображение" : attachment.filename)
        .accessibilityLabel(attachment.filename.isEmpty ? "Изображение" : attachment.filename)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let data = imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            // Заглушка пока данные загружаются
            ZStack {
                Color(nsColor: .quaternaryLabelColor).opacity(0.5)
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(attachment.filename.isEmpty ? "Изображение" : attachment.filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}
