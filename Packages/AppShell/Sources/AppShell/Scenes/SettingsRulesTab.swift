import SwiftUI
import Core
import Storage
import AI

// MARK: - Rules Tab (MailAi-pw2w / MailAi-vrge)

struct RulesSettingsTab: View {
    let registry: AccountRegistry?

    @State private var selectedAccountID: Account.ID?

    var body: some View {
        Group {
            if let registry, !registry.accounts.isEmpty {
                rulesContent(registry: registry)
            } else {
                Form {
                    Section("Правила") {
                        Label("Добавьте аккаунт, чтобы управлять правилами фильтрации",
                              systemImage: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @ViewBuilder
    private func rulesContent(registry: AccountRegistry) -> some View {
        let activeID = selectedAccountID ?? registry.accounts.first?.id
        VStack(spacing: 0) {
            if registry.accounts.count > 1, let activeID {
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
                Divider()
            }

            if let accountID = activeID,
               let pool = registry.databasePool(for: accountID) {
                RulesListView(
                    ruleEngine: RuleEngine(repository: RulesRepository(pool: pool)),
                    accountID: accountID
                )
                .id(accountID)
            } else {
                Form {
                    Section {
                        Text("База данных недоступна для выбранного аккаунта.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

// MARK: - Rule Condition (MailAi-dcx9)

/// Поле условия для конструктора правил.
enum RuleConditionField: String, CaseIterable, Identifiable {
    case from = "От (From)"
    case subject = "Тема (Subject)"
    case body = "Тело (Body)"
    case to = "Кому (To)"

    var id: String { rawValue }

    func naturalLanguageText(value: String) -> String {
        switch self {
        case .from:    return "письма от \"\(value)\""
        case .subject: return "письма с темой содержащей \"\(value)\""
        case .body:    return "письма с текстом \"\(value)\" в теле"
        case .to:      return "письма на адрес \"\(value)\""
        }
    }
}

@MainActor
struct RulesListView: View {
    let ruleEngine: RuleEngine
    let accountID: Account.ID

    @State private var rules: [Rule] = []
    @State private var isLoading = false
    @State private var newRuleText: String = ""
    @State private var newRuleIntent: Rule.Intent = .markUnimportant
    @State private var errorMessage: String?

    // MailAi-dcx9: конструктор правил
    @State private var builderMode: Bool = false
    @State private var conditionField: RuleConditionField = .from
    @State private var conditionValue: String = ""
    @State private var showDeleteConfirmID: UUID?

    var body: some View {
        Form {
            if isLoading {
                Section {
                    ProgressView("Загрузка правил…")
                }
            } else if rules.isEmpty {
                Section("Правила") {
                    Text("Правил нет. Добавьте правило ниже — оно будет передаваться AI-классификатору как инструкция.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section("Правила (\(rules.count))") {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                    }
                    .onMove { from, to in
                        rules.move(fromOffsets: from, toOffset: to)
                    }
                }
            }

            Section {
                HStack {
                    Text("Новое правило")
                        .font(.headline)
                    Spacer()
                    Button(builderMode ? "Свободный текст" : "Конструктор") {
                        builderMode.toggle()
                        if builderMode {
                            newRuleText = ""
                        } else if !conditionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            newRuleText = conditionField.naturalLanguageText(
                                value: conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.blue)
                }

                if builderMode {
                    LabeledContent("Условие") {
                        HStack(spacing: 8) {
                            Picker("", selection: $conditionField) {
                                ForEach(RuleConditionField.allCases) { field in
                                    Text(field.rawValue).tag(field)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 160)
                            .labelsHidden()

                            Text("содержит")
                                .foregroundStyle(.secondary)

                            TextField("значение", text: $conditionValue)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    LabeledContent("Действие") {
                        Picker("", selection: $newRuleIntent) {
                            Text("Помечать как неважное").tag(Rule.Intent.markUnimportant)
                            Text("Помечать как важное").tag(Rule.Intent.markImportant)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 200)
                    }

                    if !conditionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let preview = conditionField.naturalLanguageText(
                            value: conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        Text("Правило: «\(preview) → \(newRuleIntent == .markImportant ? "важное" : "неважное")»")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .italic()
                    }

                    HStack {
                        Spacer()
                        Button("Добавить правило") {
                            let value = conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            let text = conditionField.naturalLanguageText(value: value)
                            let intent = newRuleIntent
                            Task {
                                await addRule(text: text, intent: intent)
                                conditionValue = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(conditionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                } else {
                    TextField("Например: «письма от newsletter@ считать неважными»",
                              text: $newRuleText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                    HStack {
                        Picker("Действие", selection: $newRuleIntent) {
                            Text("Помечать как неважное").tag(Rule.Intent.markUnimportant)
                            Text("Помечать как важное").tag(Rule.Intent.markImportant)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        Spacer()

                        Button("Добавить") {
                            let text = newRuleText
                            let intent = newRuleIntent
                            Task {
                                await addRule(text: text, intent: intent)
                                newRuleText = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newRuleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }

            if let err = errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadRules() }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    Task { await setEnabled(rule, enabled: newValue) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.text)
                    .font(.body)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(intentLabel(rule.intent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(sourceLabel(rule.source))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                Task { await deleteRule(rule) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Удалить правило")
        }
        .padding(.vertical, 2)
    }

    private func intentLabel(_ intent: Rule.Intent) -> String {
        switch intent {
        case .markImportant:   return "Важное"
        case .markUnimportant: return "Неважное"
        }
    }

    private func sourceLabel(_ source: Rule.Source) -> String {
        switch source {
        case .manual:      return "вручную"
        case .dragConfirm: return "drag&drop"
        case .import:      return "импорт"
        }
    }

    private func loadRules() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rules = try await ruleEngine.allRules()
        } catch {
            errorMessage = "Не удалось загрузить правила"
        }
    }

    private func setEnabled(_ rule: Rule, enabled: Bool) async {
        do {
            try await ruleEngine.setEnabled(id: rule.id, enabled: enabled)
            rules = try await ruleEngine.allRules()
        } catch {
            errorMessage = "Не удалось изменить правило"
        }
    }

    private func deleteRule(_ rule: Rule) async {
        do {
            try await ruleEngine.delete(id: rule.id)
            rules = try await ruleEngine.allRules()
        } catch {
            errorMessage = "Не удалось удалить правило"
        }
    }

    private func addRule(text: String, intent: Rule.Intent) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let rule = Rule(text: trimmed, intent: intent, source: .manual)
        do {
            try await ruleEngine.save(rule)
            rules = try await ruleEngine.allRules()
            newRuleText = ""
        } catch {
            errorMessage = "Не удалось сохранить правило"
        }
    }
}
