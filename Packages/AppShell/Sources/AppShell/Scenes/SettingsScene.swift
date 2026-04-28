import SwiftUI
import Core
import Secrets
import Storage
import AI
import GRDB
import UI

/// Окно настроек приложения. Содержит вкладки "Общие", "Отфильтрованные",
/// "Подписи" и "AI-pack" (ключ OpenRouter, модель, правила классификатора).
///
/// AI-pack отображается, когда есть `AccountRegistry` и `SecretsStore`.
/// Без них показываем placeholder — это режим до C4 / mock-режим без секретов.
public struct SettingsScene: View {
    private let registry: AccountRegistry?
    private let secretsStore: (any SecretsStore)?
    private let databasePool: DatabasePool?

    public init(
        registry: AccountRegistry? = nil,
        secretsStore: (any SecretsStore)? = nil,
        databasePool: DatabasePool? = nil
    ) {
        self.registry = registry
        self.secretsStore = secretsStore
        self.databasePool = databasePool
    }

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Общие", systemImage: "gearshape") }
            FilteredSettingsView()
                .tabItem { Label("Отфильтрованные", systemImage: "sparkles") }
            SignaturesSettingsTab(databasePool: databasePool)
                .tabItem { Label("Подписи", systemImage: "signature") }
            AIPackSettingsTab(registry: registry, secretsStore: secretsStore)
                .tabItem { Label("AI-pack", systemImage: "wand.and.stars") }
            PromptEditorTab()
                .tabItem { Label("AI Промпты", systemImage: "text.badge.plus") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettingsView: View {
    @StateObject private var cacheVM = CacheSettingsViewModel()

    var body: some View {
        Form {
            Section("Аккаунты") {
                Text("Управление аккаунтами — через первое окно (Welcome).")
                    .foregroundStyle(.secondary)
            }

            Section("Кеш") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Письма и вложения")
                        Text(cacheVM.formattedSize)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Очистить кеш", role: .destructive) {
                        Task { await cacheVM.clearCache() }
                    }
                }
                LabeledContent("Максимальный размер кеша") {
                    Stepper(
                        value: $cacheVM.limitMB,
                        in: 50...10240,
                        step: 50,
                        onEditingChanged: { _ in cacheVM.updateLimit() }
                    ) {
                        Text("\(cacheVM.limitMB) МБ")
                    }
                }
            }

            Section("Приватность") {
                Toggle("Блокировать внешние изображения",
                       isOn: Binding(
                           get: { UserDefaults.standard.bool(forKey: "blockExternalImages") },
                           set: { UserDefaults.standard.set($0, forKey: "blockExternalImages") }
                       ))
                Text("Скрывает трекер-пиксели и внешние картинки. Кнопка «Показать изображения» позволяет разрешить для отдельного письма.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task { await cacheVM.refresh() }
    }
}

private struct FilteredSettingsView: View {
    var body: some View {
        Form {
            Section("AI-классификация") {
                Text("Папка «Отфильтрованные» собирает письма, которые AI-pack пометил как неважные. Включить и настроить — во вкладке AI-pack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Signatures Tab

private struct SignaturesSettingsTab: View {
    let databasePool: DatabasePool?

    var body: some View {
        Group {
            if let pool = databasePool {
                SignaturesSettingsView(
                    viewModel: SignaturesViewModel(
                        repository: SignaturesRepository(pool: pool)
                    )
                )
            } else {
                Form {
                    Section("Подписи") {
                        Label("База данных недоступна — откройте аккаунт, чтобы управлять подписями.",
                              systemImage: "signature")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

private struct SignaturesSettingsView: View {
    @StateObject private var viewModel: SignaturesViewModel

    @State private var editingName: String = ""
    @State private var editingBody: String = ""
    @State private var editingIsDefault: Bool = false

    init(viewModel: SignaturesViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        HSplitView {
            // MARK: Left panel — list
            VStack(spacing: 0) {
                List(viewModel.signatures, id: \.id, selection: $viewModel.selectedID) { sig in
                    Text(sig.name)
                        .lineLimit(1)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 160, idealWidth: 180)

                Divider()

                HStack(spacing: 0) {
                    Button {
                        Task { await viewModel.add() }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Добавить подпись")

                    Button {
                        if let id = viewModel.selectedID {
                            Task { await viewModel.delete(id) }
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.selectedID == nil)
                    .help("Удалить подпись")

                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.bar)
            }

            // MARK: Right panel — editor
            VStack(alignment: .leading, spacing: 12) {
                if let selected = viewModel.selected {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Название")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Название подписи", text: $editingName)
                            .textFieldStyle(.roundedBorder)

                        Text("Текст подписи")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $editingBody)
                            .font(.body)
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )

                        Toggle("Использовать по умолчанию", isOn: $editingIsDefault)
                            .toggleStyle(.checkbox)

                        HStack {
                            Spacer()
                            Button("Сохранить") {
                                let name = editingName
                                let body = editingBody
                                let isDefault = editingIsDefault
                                Task { await viewModel.save(name: name, body: body, isDefault: isDefault) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding()
                    .id(selected.id) // сбрасываем поля при смене выбора
                    .onAppear {
                        editingName = selected.name
                        editingBody = selected.body
                        editingIsDefault = selected.isDefault
                    }
                    .onChange(of: viewModel.selectedID) { _, _ in
                        if let s = viewModel.selected {
                            editingName = s.name
                            editingBody = s.body
                            editingIsDefault = s.isDefault
                        }
                    }
                } else {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Выберите подпись или добавьте новую")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .frame(minWidth: 280)
        }
        .task { await viewModel.load() }
    }
}

// MARK: - AI-pack Tab

private struct AIPackSettingsTab: View {
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
                .id(id) // пересоздаём VM при смене аккаунта
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

private struct AIPackSettingsView: View {
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

// MARK: - Prompt Editor Tab

private struct PromptEditorTab: View {
    @StateObject private var viewModel = PromptEditorViewModel()
    @State private var editingContent: String = ""

    var body: some View {
        HSplitView {
            // MARK: Left — prompt list
            List(viewModel.entries, selection: $viewModel.selectedID) { entry in
                Label(entry.displayName, systemImage: entry.icon)
                    .tag(entry.id)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160, idealWidth: 180)

            // MARK: Right — editor
            VStack(spacing: 0) {
                if viewModel.selectedEntry != nil {
                    TextEditor(text: $editingContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    HStack(spacing: 12) {
                        Text(statusLabel)
                            .font(.caption)
                            .foregroundStyle(isCustom ? Color.accentColor : .secondary)
                        Spacer()
                        Button("Сбросить") {
                            Task {
                                await viewModel.reset()
                                syncEditing()
                            }
                        }
                        .disabled(!isCustom)
                        Button("Сохранить") {
                            let content = editingContent
                            Task { await viewModel.save(content: content) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
                } else {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Выберите промпт для редактирования")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .frame(minWidth: 280)
        }
        .task { await viewModel.load(); syncEditing() }
        .onChange(of: viewModel.selectedID) { _, _ in syncEditing() }
        .onChange(of: viewModel.selectedEntry?.content) { _, newContent in
            // Sync when entry content is updated externally (e.g. after reset)
            if let newContent, editingContent != newContent {
                editingContent = newContent
            }
        }
    }

    private var isCustom: Bool { viewModel.selectedEntry?.isCustom ?? false }

    private var statusLabel: String {
        isCustom ? "Изменён" : "Стандартный"
    }

    private func syncEditing() {
        editingContent = viewModel.selectedEntry?.content ?? ""
    }
}
