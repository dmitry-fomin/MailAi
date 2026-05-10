import SwiftUI

/// Первый шаг онбординга — выбор типа аккаунта (IMAP или Exchange).
public struct AccountTypePickerScene: View {
    public var onSelectIMAP: () -> Void
    public var onSelectExchange: () -> Void
    public var onCancel: () -> Void

    public init(
        onSelectIMAP: @escaping () -> Void,
        onSelectExchange: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelectIMAP = onSelectIMAP
        self.onSelectExchange = onSelectExchange
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text("Добавить аккаунт")
                .font(.title2.weight(.semibold))

            VStack(spacing: 12) {
                accountTypeButton(
                    icon: "envelope.fill",
                    title: "IMAP",
                    subtitle: "Gmail, Яндекс, Mail.ru, собственный сервер",
                    action: onSelectIMAP
                )
                accountTypeButton(
                    icon: "building.2.fill",
                    title: "Exchange (EWS)",
                    subtitle: "Корпоративная почта Microsoft Exchange on-premise",
                    action: onSelectExchange
                )
            }
            .frame(maxWidth: 400)

            HStack {
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 320)
    }

    @ViewBuilder
    private func accountTypeButton(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 36)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
