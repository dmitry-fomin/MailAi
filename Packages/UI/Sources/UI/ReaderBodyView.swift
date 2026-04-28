import SwiftUI
import Core

/// Рендер тела письма.
/// Plain text — нативный SwiftUI Text.
/// HTML — WKWebView через MessageWebView с кешем, dark mode и quote-collapsing.
public struct ReaderBodyView: View {
    public let messageBody: MessageBody
    public let messageID: String
    public let attachments: [Attachment]
    public let cacheManager: CacheManager
    public var onSaveAttachment: (Attachment) -> Void
    @Binding public var isFocused: Bool
    @State private var processedEmail: ProcessedEmail?
    @State private var showImages: Bool = false
    /// Масштаб текста для HTML-писем. 1.0 = 100%, 1.5 = 150%.
    /// Читается из UserDefaults; обновляется без перезагрузки страницы.
    @AppStorage("readerTextZoom") private var textZoom: Double = 1.0

    public init(
        body: MessageBody,
        messageID: String,
        attachments: [Attachment] = [],
        cacheManager: CacheManager,
        onSaveAttachment: @escaping (Attachment) -> Void = { _ in },
        isFocused: Binding<Bool> = .constant(false)
    ) {
        self.messageBody = body
        self.messageID = messageID
        self.attachments = attachments
        self.cacheManager = cacheManager
        self.onSaveAttachment = onSaveAttachment
        self._isFocused = isFocused
    }

    public var body: some View {
        KeyboardScrollableReader(isFocused: $isFocused) {
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !attachments.isEmpty {
                    Divider().padding(.top, 8)
                    AttachmentListView(
                        attachments: attachments,
                        onSaveAs: { onSaveAttachment($0) }
                    )
                }
            }
            .padding(16)
        }
        .task(id: messageID) { await loadHTML() }
    }

    @ViewBuilder private var content: some View {
        switch messageBody.content {
        case .plain(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        case .html:
            if let email = processedEmail {
                VStack(alignment: .leading, spacing: 4) {
                    if email.hasExternalImages && !showImages {
                        Button("Показать изображения") {
                            showImages = true
                            Task { await loadHTML() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    MessageWebView(
                        processedEmail: email,
                        messageID: messageID,
                        cacheManager: cacheManager,
                        textZoom: textZoom
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        }
    }

    private func loadHTML() async {
        guard case .html(let rawHTML) = messageBody.content else { return }
        let blockImages = !showImages && UserDefaults.standard.bool(forKey: "blockExternalImages")

        if !showImages, let cached = await cacheManager.readBody(messageID: messageID) {
            processedEmail = ProcessedEmail(
                html: cached,
                hasDarkModeSupport: cached.contains("prefers-color-scheme"),
                hasExternalImages: cached.range(of: #"src\s*=\s*["']https?://"#, options: .regularExpression) != nil
            )
            return
        }

        let email = await HTMLPreprocessor().process(rawHTML, blockExternalImages: blockImages)
        if !showImages {
            await cacheManager.writeBody(messageID: messageID, processedHTML: email.html)
        }
        processedEmail = email
    }
}
