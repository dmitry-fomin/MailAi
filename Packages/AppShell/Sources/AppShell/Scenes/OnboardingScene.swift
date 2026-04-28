import SwiftUI
import Core

/// Форма добавления IMAP-аккаунта. C4.
///
/// SMTP-секция появляется автоматически после ввода email:
/// - Если `IMAPAutoconfig` нашёл настройки — поля заполняются автоматически.
/// - Если нет — секция появляется пустой для ручного ввода.
/// Кнопка «Проверить и сохранить» заблокирована, пока SMTP-поля не заполнены.
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
                        .onSubmit {
                            Task { await model.runAutoconfig() }
                        }
                    SecureField("Пароль (IMAP)", text: $model.password)
                    TextField("Имя для отображения (необязательно)", text: $model.displayName)
                    TextField("Username (если отличается от email)", text: $model.username)
                }

                Section("IMAP-сервер") {
                    HStack {
                        TextField("Host (imap.example.com)", text: $model.host)
                        if model.isAutoconfiguring {
                            ProgressView().controlSize(.small)
                        }
                    }
                    TextField("Порт", text: $model.portText)
                    Toggle("Использовать TLS (SSL)", isOn: $model.useTLS)
                }

                if model.showSMTPSection {
                    smtpSection
                }
            }
            .formStyle(.grouped)

            statusView
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if !model.showSMTPSection && !model.isAutoconfiguring {
                    Button("Определить настройки") {
                        Task { await model.runAutoconfig() }
                    }
                    .buttonStyle(.bordered)
                }

                Button("Проверить и сохранить") {
                    Task { await model.submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 560)
        .onChange(of: model.phase) { _, newValue in
            if case .succeeded(let account) = newValue {
                onCompleted(account)
            }
        }
    }

    // MARK: - SMTP Section

    @ViewBuilder
    private var smtpSection: some View {
        Section("SMTP-сервер (исходящая почта)") {
            TextField("Host (smtp.example.com)", text: $model.smtpHost)
            TextField("Порт", text: $model.smtpPortText)
            Toggle("Использовать SSL (порт 465)", isOn: $model.smtpUseTLS)
                .onChange(of: model.smtpUseTLS) { _, useTLS in
                    // Автоподстановка стандартного порта при переключении.
                    if useTLS && model.smtpPortText == "587" {
                        model.smtpPortText = "465"
                    } else if !useTLS && model.smtpPortText == "465" {
                        model.smtpPortText = "587"
                    }
                }

            Toggle("Использовать пароль IMAP для SMTP", isOn: $model.smtpUseSamePassword)

            if !model.smtpUseSamePassword {
                SecureField("Пароль SMTP (Application Password)", text: $model.smtpPassword)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Status View

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
