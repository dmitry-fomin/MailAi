import SwiftUI
import Core

/// Стартовое окно. Показывается если нет ни одного подключённого аккаунта
/// (или в `--mock`-режиме — как dev-entry).
public struct WelcomeScene: View {
    public var onAddAccount: () -> Void
    public var onContinueWithMock: () -> Void

    public init(
        onAddAccount: @escaping () -> Void,
        onContinueWithMock: @escaping () -> Void
    ) {
        self.onAddAccount = onAddAccount
        self.onContinueWithMock = onContinueWithMock
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.circle.fill")
                .resizable()
                .frame(width: 96, height: 96)
                .foregroundStyle(.tint)

            Text("MailAi")
                .font(.largeTitle.weight(.semibold))

            Text("Нативный почтовый клиент с AI — без отправки писем в облако.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button {
                    onAddAccount()
                } label: {
                    Text("Добавить аккаунт")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                Button {
                    onContinueWithMock()
                } label: {
                    Text("Продолжить с демо-данными")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 280)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 420)
    }
}
