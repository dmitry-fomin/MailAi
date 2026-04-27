import SwiftUI
import Core

/// Секция вложений внизу письма. Если вложений нет — не рендерится.
public struct AttachmentListView: View {
    public let attachments: [Attachment]
    public var onQuickLook: (Attachment) -> Void
    public var onSaveAs: (Attachment) -> Void

    public init(
        attachments: [Attachment],
        onQuickLook: @escaping (Attachment) -> Void = { _ in },
        onSaveAs: @escaping (Attachment) -> Void = { _ in }
    ) {
        self.attachments = attachments
        self.onQuickLook = onQuickLook
        self.onSaveAs = onSaveAs
    }

    public var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Вложения")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(attachments) { att in
                    AttachmentRowView(
                        attachment: att,
                        onQuickLook: { onQuickLook(att) },
                        onSaveAs: { onSaveAs(att) }
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
}
