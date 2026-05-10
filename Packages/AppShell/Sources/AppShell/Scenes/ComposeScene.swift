import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core
import UI

/// SMTP-5: окно «Новое письмо». Поля To/Cc/Bcc/Subject + multiline-тело,
/// кнопки «Отправить» / «Сохранить черновик», индикатор состояния и
/// confirmation на закрытии при непустом черновике.
///
/// Поля адресатов реализованы через `AddressTokenField` — каждый введённый
/// адрес превращается в токен (chip). Тело письма — NSTextView через TextEditor.
/// Вложения: drag-and-drop файлов на окно, кнопка «Прикрепить» (NSOpenPanel),
/// список прикреплённых файлов с кнопкой удаления.
public struct ComposeScene: View {
    @ObservedObject var model: ComposeViewModel

    /// Колбек закрытия — окно вызывает `dismissWindow` через него.
    let onClose: () -> Void

    @State private var showCloseConfirmation: Bool = false
    @State private var isDragTargeted: Bool = false

    public init(model: ComposeViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 480, idealHeight: 600)
        .overlay(dragOverlay)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: model.didFinish) { _, finished in
            if finished { onClose() }
        }
        .confirmationDialog(
            "Закрыть письмо без отправки?",
            isPresented: $showCloseConfirmation
        ) {
            Button("Сохранить черновик") {
                Task {
                    await model.saveDraft()
                    if case .saved = model.draftState {
                        onClose()
                    }
                }
            }
            .disabled(!model.canSaveDraft)
            Button("Закрыть без сохранения", role: .destructive) {
                onClose()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("В письме есть несохранённые изменения.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(windowTitle)
                .font(.headline)
            Spacer()
            Text("От: \(model.accountEmail)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var windowTitle: String {
        if model.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Новое письмо"
        }
        return model.subject
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tokenRecipientRow(
                    title: "Кому",
                    tokens: $model.toTokens,
                    isValid: model.toTokens.isEmpty || model.isToValid,
                    placeholder: "name@example.com, …"
                )
                Divider().padding(.leading, 72)

                tokenRecipientRow(
                    title: "Копия",
                    tokens: $model.ccTokens,
                    isValid: model.isCcValid,
                    placeholder: "необязательно"
                )
                Divider().padding(.leading, 72)

                tokenRecipientRow(
                    title: "Скрытая",
                    tokens: $model.bccTokens,
                    isValid: model.isBccValid,
                    placeholder: "необязательно"
                )
                Divider().padding(.leading, 72)

                subjectRow
                Divider().padding(.leading, 72)

                bodyField
            }
        }
    }

    // MARK: - Token recipient row

    @ViewBuilder
    private func tokenRecipientRow(
        title: String,
        tokens: Binding<[String]>,
        isValid: Bool,
        placeholder: String
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 10)
                .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 2) {
                AddressTokenField(tokens: tokens, placeholder: placeholder)
                    .padding(.vertical, 4)

                if !isValid {
                    Text("Проверьте формат адресов")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.bottom, 2)
                }
            }
            .padding(.trailing, 16)
        }
        .padding(.leading, 8)
    }

    // MARK: - Subject row

    private var subjectRow: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("Тема")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .padding(.trailing, 8)

            TextField("Без темы", text: $model.subject)
                .font(.body)
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .padding(.trailing, 16)
        }
        .padding(.leading, 8)
    }

    // MARK: - Body field

    private var bodyField: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.body)
                .font(.body)
                .frame(minHeight: 180)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            if !model.attachedFiles.isEmpty {
                Divider()
                attachmentsSection
            }
        }
    }

    // MARK: - Attachments section

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Вложения (\(model.attachedFiles.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let warning = model.attachmentSizeWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            ForEach(model.attachedFiles) { att in
                ComposeAttachmentRow(
                    attachment: att,
                    onRemove: { model.removeAttachment(id: att.id) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Drag overlay

    @ViewBuilder
    private var dragOverlay: some View {
        if isDragTargeted {
            ZStack {
                Color(nsColor: .controlAccentColor).opacity(0.15)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .controlAccentColor), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .padding(8)
                VStack(spacing: 8) {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                    Text("Отпустите для прикрепления")
                        .font(.headline)
                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Drop handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        self.model.attachFile(url: url)
                    }
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // Кнопка прикрепления файлов
            Button {
                openAttachmentPicker()
            } label: {
                Label("Прикрепить", systemImage: "paperclip")
            }
            .help("Прикрепить файл (⌥⌘A)")
            .keyboardShortcut("a", modifiers: [.option, .command])

            statusLabel
            Spacer()
            Button("Закрыть") {
                requestClose()
            }
            .keyboardShortcut(.cancelAction)
            Button("Сохранить черновик") {
                Task { await model.saveDraft() }
            }
            .disabled(!model.canSaveDraft || isBusy)
            Button("Отправить") {
                Task { await model.send() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSend || !model.isFormValid || isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Attachment picker (NSOpenPanel)

    private func openAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Прикрепить"
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls {
                    model.attachFile(url: url)
                }
            }
        }
    }

    private var isBusy: Bool {
        if case .sending = model.sendState { return true }
        if case .saving = model.draftState { return true }
        return false
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch (model.sendState, model.draftState) {
        case (.sending, _):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Отправляем…").font(.caption).foregroundStyle(.secondary)
            }
        case (_, .saving):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Сохраняем черновик…").font(.caption).foregroundStyle(.secondary)
            }
        case (.error(let msg), _):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case (_, .error(let msg)):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case (_, .saved):
            Label("Черновик сохранён", systemImage: "tray.and.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        case (.sent, _):
            Label("Отправлено", systemImage: "paperplane")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func requestClose() {
        if model.hasUnsavedContent {
            showCloseConfirmation = true
        } else {
            onClose()
        }
    }
}
