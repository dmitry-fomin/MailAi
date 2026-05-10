import SwiftUI
import Core
import Secrets
import Storage
import AI

// MARK: - AI-pack Tab

struct AIPackSettingsTab: View {
    let registry: AccountRegistry?
    let secretsStore: (any SecretsStore)?

    @State private var selectedAccountID: Account.ID?

    var body: some View {
        Group {
            if let registry, let secretsStore, !registry.accounts.isEmpty {
                content(registry: registry, secretsStore: secretsStore)
            } else {
                Form {
                    Section("AI-pack") {
                        Label("Добавьте аккаунт, чтобы настроить AI-pack",
                              systemImage: "person.crop.circle.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @ViewBuilder
    private func content(registry: AccountRegistry, secretsStore: any SecretsStore) -> some View {
        let activeID = selectedAccountID ?? registry.accounts.first?.id
        VStack(spacing: 0) {
            if registry.accounts.count > 1, let activeID {
                accountPicker(registry: registry, activeID: activeID)
                Divider()
            }
            if let id = activeID, let account = registry.account(with: id) {
                AIPackSettingsView(
                    accountID: id,
                    accountEmail: account.email,
                    registry: registry,
                    secretsStore: secretsStore
                )
                .id(id)
            }
        }
    }

    private func accountPicker(registry: AccountRegistry, activeID: Account.ID) -> some View {
        HStack {
            Text("Аккаунт")
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { activeID },
                set: { selectedAccountID = $0 }
            )) {
                ForEach(registry.accounts, id: \.id) { account in
                    Text(account.email).tag(account.id)
                }
            }
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct AIPackSettingsView: View {
    let accountID: Account.ID
    let accountEmail: String
    let registry: AccountRegistry
    let secretsStore: any SecretsStore

    @StateObject private var model: AISettingsViewModel

    @State private var newRuleText: String = ""
    @State private var newRuleIntent: Rule.Intent = .markUnimportant

    init(
        accountID: Account.ID,
        accountEmail: String,
        registry: AccountRegistry,
        secretsStore: any SecretsStore
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.registry = registry
        self.secretsStore = secretsStore
        let ruleEngine: RuleEngine? = registry.databasePool(for: accountID).map {
            RuleEngine(repository: RulesRepository(pool: $0))
        }
        _model = StateObject(wrappedValue: AISettingsViewModel(
            accountID: accountID,
            accountEmail: accountEmail,
            secrets: secretsStore,
            settings: AISettingsStore(),
            ruleEngine: ruleEngine
        ))
    }

    var body: some View {
        Form {
            enableSection
            keySection
            modelSection
            serverSyncSection
            rulesSection
            if let status = model.statusMessage, !status.isEmpty {
                Section {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.aiPackEnabled },
                set: { newValue in
                    Task { await model.setAIPackEnabled(newValue) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI-pack включён")
                    Text("Без AI-pack приложение работает в v1-режиме: классификация и AI-фильтры выключены.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.aiPackEnabled && model.apiKey.isEmpty {
                Label("Без ключа AI-pack не активен — добавьте ключ ниже.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var keySection: some View {
        Section("OpenRouter API key") {
            SecureField("sk-or-…", text: $model.apiKey, prompt: Text("Введите ключ"))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            HStack {
                Button("Сохранить") {
                    Task { await model.saveAPIKey() }
                }
                .disabled(model.isLoading)
                Button("Удалить", role: .destructive) {
                    Task { await model.clearAPIKey() }
                }
                .disabled(model.apiKey.isEmpty || model.isLoading)
                Spacer()
                Link("Получить ключ",
                     destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.caption)
            }
            Text("Ключ хранится в Keychain. В логи и БД не попадает.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section("Модель") {
            Picker("Модель OpenRouter", selection: Binding(
                get: { model.modelID },
                set: { newValue in
                    Task { await model.setModelID(newValue) }
                }
            )) {
                ForEach(model.availableModels, id: \.id) { entry in
                    Text("\(entry.displayName) — \(entry.provider)")
                        .tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            Text("Используется для классификации входящих писем.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serverSyncSection: some View {
        Section("Серверная синхронизация") {
            Toggle(isOn: Binding(
                get: { model.serverSyncEnabled },
                set: { newValue in
                    Task { await model.setServerSyncEnabled(newValue) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Синхронизировать с сервером (Important/Unimportant папки)")
                    Text("После классификации новые письма переносятся в серверные папки MailAi/Important и MailAi/Unimportant. Старые письма не перемещаются.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!model.aiPackEnabled)
        }
    }

    private var rulesSection: some View {
        Section("Правила") {
            if model.rules.isEmpty {
                Text("Правил пока нет. Добавьте формулировку ниже — она будет подставлена в system-prompt классификатора.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.rules) { rule in
                    ruleRow(rule)
                }
            }
            addRuleRow
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    Task { await model.setRuleEnabled(rule, enabled: newValue) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.text)
                    .font(.body)
                    .lineLimit(3)
                Text(intentLabel(rule.intent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.deleteRule(rule) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Удалить правило")
        }
        .padding(.vertical, 2)
    }

    private var addRuleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Новое правило")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Например: «письма от noreply считать неважными»",
                      text: $newRuleText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Picker("", selection: $newRuleIntent) {
                    Text("Помечать как неважное")
                        .tag(Rule.Intent.markUnimportant)
                    Text("Помечать как важное")
                        .tag(Rule.Intent.markImportant)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
                Button("Добавить") {
                    let text = newRuleText
                    let intent = newRuleIntent
                    Task {
                        await model.addRule(text: text, intent: intent)
                        await MainActor.run {
                            newRuleText = ""
                        }
                    }
                }
                .disabled(newRuleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private func intentLabel(_ intent: Rule.Intent) -> String {
        switch intent {
        case .markImportant: return "Помечать как важное"
        case .markUnimportant: return "Помечать как неважное"
        }
    }
}
