import SwiftUI
import Core

/// Форма добавления Exchange-аккаунта (on-premise EWS).
public struct ExchangeOnboardingScene: View {
    @ObservedObject var model: ExchangeOnboardingViewModel
    public var onCancel: () -> Void
    public var onCompleted: (Account) -> Void

    public init(
        model: ExchangeOnboardingViewModel,
        onCancel: @escaping () -> Void,
        onCompleted: @escaping (Account) -> Void
    ) {
        self.model = model
        self.onCancel = onCancel
        self.onCompleted = onCompleted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Добавить Exchange-аккаунт")
                .font(.title2.weight(.semibold))

            Form {
                Section("Учётные данные") {
                    TextField("Email", text: $model.email)
                        .textContentType(.emailAddress)
                    SecureField("Пароль", text: $model.password)
                    TextField("Имя для отображения (необязательно)", text: $model.displayName)
                }

                Section {
                    Toggle("Указать EWS URL вручную", isOn: $model.showManualURL)
                    if model.showManualURL {
                        TextField(
                            "https://mail.example.com/EWS/Exchange.asmx",
                            text: $model.ewsURLOverride
                        )
                        .textContentType(.URL)
                    } else {
                        if !model.discoveredURLString.isEmpty {
                            LabeledContent("Обнаружен сервер") {
                                Text(model.discoveredURLString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Сервер будет найден автоматически через Autodiscover")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Сервер")
                }
            }
            .formStyle(.grouped)

            statusView
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(submitTitle) {
                    Task { await model.submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 480)
        .onChange(of: model.phase) { _, newValue in
            if case .succeeded(let account) = newValue {
                onCompleted(account)
            }
        }
    }

    private var submitTitle: String {
        switch model.phase {
        case .discovering: return "Поиск…"
        case .validating: return "Проверка…"
        default: return "Проверить и сохранить"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .discovering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Ищем Exchange-сервер через Autodiscover…")
            }
            .foregroundStyle(.secondary)
        case .validating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Проверяем подключение к Exchange…")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .onTapGesture { model.resetError() }
        case .succeeded:
            Label("Exchange-аккаунт добавлен", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
    }
}
