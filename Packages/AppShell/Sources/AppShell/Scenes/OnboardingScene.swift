import SwiftUI
import Core

/// Форма добавления IMAP-аккаунта. C4.
public struct OnboardingScene: View {
    @ObservedObject var model: OnboardingViewModel
    public var onCancel: () -> Void
    public var onCompleted: (Account) -> Void

    public init(
        model: OnboardingViewModel,
        onCancel: @escaping () -> Void,
        onCompleted: @escaping (Account) -> Void
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onCompleted = onCompleted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Добавить IMAP-аккаунт")
                .font(.title2.weight(.semibold))

            Form {
                Section("Учётные данные") {
                    TextField("Email", text: $model.email)
                        .textContentType(.emailAddress)
                    SecureField("Пароль", text: $model.password)
                    TextField("Имя для отображения (необязательно)", text: $model.displayName)
                    TextField("Username (если отличается от email)", text: $model.username)
                }

                Section("Сервер") {
                    TextField("Host (imap.example.com)", text: $model.host)
                    TextField("Порт", text: $model.portText)
                    Toggle("Использовать TLS (SSL)", isOn: $model.useTLS)
                }
            }
            .formStyle(.grouped)

            statusView
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Проверить и сохранить") {
                    Task { await model.submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 520)
        .onChange(of: model.phase) { _, newValue in
            if case .succeeded(let account) = newValue {
                onCompleted(account)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .validating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Проверяем подключение…")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .onTapGesture { model.resetError() }
        case .succeeded:
            Label("Аккаунт добавлен", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
    }
}
