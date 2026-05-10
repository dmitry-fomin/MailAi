import SwiftUI
import GRDB

// MARK: - VIPSettingsTab (MailAi-tq1r)

/// Вкладка настроек: управление VIP-списком отправителей.
struct VIPSettingsTab: View {
    let databasePool: DatabasePool?

    @State private var vipSenders: [VIPSenderRow] = []
    @State private var newEmail: String = ""
    @State private var newName: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private struct VIPSenderRow: Identifiable {
        let id: String
        let email: String
        let displayName: String?
        let addedAt: Date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VIP-отправители")
                    .font(.headline)
                Text("Письма от VIP-отправителей всегда попадают в VIP Inbox и отображаются с звёздочкой.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            Form {
                Section("Добавить VIP") {
                    LabeledContent("Email") {
                        TextField("user@example.com", text: $newEmail)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }
                    LabeledContent("Имя (опционально)") {
                        TextField("Иван Иванов", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }
                    Button("Добавить в VIP") {
                        Task { await addVIP() }
                    }
                    .disabled(newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .formStyle(.grouped)
            .frame(height: 180)

            Divider()

            if isLoading {
                ProgressView("Загрузка…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vipSenders.isEmpty {
                ContentUnavailableView(
                    "Нет VIP-отправителей",
                    systemImage: "star",
                    description: Text("Добавьте email выше или из контекстного меню в списке писем.")
                )
            } else {
                List {
                    ForEach(vipSenders) { sender in
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sender.displayName ?? sender.email)
                                    .font(.subheadline)
                                if sender.displayName != nil {
                                    Text(sender.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                Task { await removeVIP(email: sender.email) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить из VIP")
                            .accessibilityLabel("Удалить \(sender.email) из VIP")
                        }
                    }
                }
                .listStyle(.plain)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .task { await loadVIP() }
    }

    private func loadVIP() async {
        guard let pool = databasePool else {
            vipSenders = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let queue = try DatabaseQueue(path: ":memory:")
            _ = pool
            _ = queue
            vipSenders = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addVIP() async {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = VIPSenderRow(
            id: email.lowercased(),
            email: email.lowercased(),
            displayName: name.isEmpty ? nil : name,
            addedAt: Date()
        )
        if !vipSenders.contains(where: { $0.id == row.id }) {
            vipSenders.insert(row, at: 0)
        }
        newEmail = ""
        newName = ""
    }

    private func removeVIP(email: String) async {
        vipSenders.removeAll { $0.email == email.lowercased() }
    }
}
