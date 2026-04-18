import SwiftUI
import Core

/// Picker, который открывается по File → New Account Window…
/// Показывает список зарегистрированных аккаунтов и даёт кнопку открыть окно
/// для выбранного. Если окно с этим `Account.ID` уже открыто, SwiftUI
/// сфокусирует его вместо создания дубля.
public struct AccountPickerScene: View {
    @ObservedObject public var registry: AccountRegistry
    public var onOpen: (Account.ID) -> Void
    public var onAddAccount: () -> Void

    public init(
        registry: AccountRegistry,
        onOpen: @escaping (Account.ID) -> Void,
        onAddAccount: @escaping () -> Void = {}
    ) {
        self.registry = registry
        self.onOpen = onOpen
        self.onAddAccount = onAddAccount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Выберите аккаунт")
                .font(.title3.weight(.semibold))

            if registry.accounts.isEmpty {
                ContentUnavailableView(
                    "Нет аккаунтов",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Добавьте почтовый аккаунт, чтобы открыть окно.")
                )
                .frame(minHeight: 180)
            } else {
                List(registry.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.displayName ?? account.email)
                                .font(.body.weight(.medium))
                            Text(account.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Открыть") {
                            onOpen(account.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
            }

            HStack {
                Button("Добавить аккаунт…", action: onAddAccount)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }
}
