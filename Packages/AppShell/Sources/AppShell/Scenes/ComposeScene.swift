import SwiftUI
import Core

/// SMTP-5: окно «Новое письмо». Поля To/Cc/Bcc/Subject + multiline-тело,
/// кнопки «Отправить» / «Сохранить черновик», индикатор состояния и
/// confirmation на закрытии при непустом черновике.
public struct ComposeScene: View {
    @ObservedObject var model: ComposeViewModel

    /// Колбек закрытия — окно вызывает `dismissWindow` через него.
    let onClose: () -> Void

    @State private var showCloseConfirmation: Bool = false

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
            Text("Новое письмо")
                .font(.headline)
            Spacer()
            Text("От: \(model.accountEmail)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                recipientField(
                    title: "Кому",
                    text: $model.to,
                    isValid: model.to.isEmpty || model.isToValid,
                    placeholder: "name@example.com, …"
                )
                recipientField(
                    title: "Копия",
                    text: $model.cc,
                    isValid: model.isCcValid,
                    placeholder: "необязательно"
                )
                recipientField(
                    title: "Скрытая копия",
                    text: $model.bcc,
                    isValid: model.isBccValid,
                    placeholder: "необязательно"
                )
                subjectField
                bodyField
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func recipientField(
        title: String,
        text: Binding<String>,
        isValid: Bool,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isValid ? Color.clear : Color.red.opacity(0.6), lineWidth: 1)
                )
            if !isValid {
                Text("Проверьте формат адресов")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var subjectField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Тема")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Без темы", text: $model.subject)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Текст")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.body)
                .font(.body)
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
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
