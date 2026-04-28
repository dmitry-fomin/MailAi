import SwiftUI
import Core
import Secrets
import Storage
import AI
import GRDB
import UI

// MARK: - SyncDepth (MailAi-uamg)

/// Глубина начальной синхронизации при первом подключении аккаунта.
/// Хранится в UserDefaults под ключом "syncDepth".
public enum SyncDepth: String, CaseIterable, Sendable {
    case week7 = "7d"
    case days30 = "30d"
    case months3 = "3m"
    case all = "all"

    public var displayName: String {
        switch self {
        case .week7:   return "7 дней"
        case .days30:  return "30 дней"
        case .months3: return "3 месяца"
        case .all:     return "Всё"
        }
    }

    /// Дата отсечения для initial sync. nil — тянуть всё.
    public var cutoffDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .week7:   return cal.date(byAdding: .day, value: -7, to: now)
        case .days30:  return cal.date(byAdding: .day, value: -30, to: now)
        case .months3: return cal.date(byAdding: .month, value: -3, to: now)
        case .all:     return nil
        }
    }

    public static var current: SyncDepth {
        let raw = UserDefaults.standard.string(forKey: "syncDepth") ?? ""
        return SyncDepth(rawValue: raw) ?? .week7
    }
}

// MARK: - SettingsScene

/// Окно настроек приложения. Содержит вкладки:
/// «Общие», «Аккаунты», «Уведомления», «Подписи», «Правила», «AI-pack», «AI Промпты».
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

    private var dbQueue: DatabaseQueue? {
        // DatabasePool conformance — wraps first connection for VIPList.
        // В реальном коде передавать DatabaseQueue напрямую или через DI.
        nil
    }

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Общие", systemImage: "gearshape") }
            AccountsSettingsView(registry: registry, secretsStore: secretsStore)
                .tabItem { Label("Аккаунты", systemImage: "person.crop.circle") }
            NotificationsSettingsView()
                .tabItem { Label("Уведомления", systemImage: "bell") }
            SignaturesSettingsTab(databasePool: databasePool, registry: registry)
                .tabItem { Label("Подписи", systemImage: "signature") }
            RulesSettingsTab(registry: registry)
                .tabItem { Label("Правила", systemImage: "line.3.horizontal.decrease.circle") }
            AIPackSettingsTab(registry: registry, secretsStore: secretsStore)
                .tabItem { Label("AI-pack", systemImage: "wand.and.stars") }
            PromptEditorTab()
                .tabItem { Label("AI Промпты", systemImage: "text.badge.plus") }
            // MailAi-tq1r: VIP-список отправителей
            VIPSettingsTab(databasePool: databasePool)
                .tabItem { Label("VIP", systemImage: "star.fill") }
        }
        .frame(width: 600, height: 540)
    }
}

// MARK: - General Tab

private struct GeneralSettingsView: View {
    @StateObject private var cacheVM = CacheSettingsViewModel()
    @State private var syncDepth: SyncDepth = SyncDepth.current
    @AppStorage("syncIntervalMinutes") private var syncIntervalMinutes: Int = 5

    var body: some View {
        Form {
            // MARK: Синхронизация
            Section("Синхронизация") {
                LabeledContent("Интервал polling'а") {
                    Picker("", selection: $syncIntervalMinutes) {
                        Text("1 мин").tag(1)
                        Text("5 мин").tag(5)
                        Text("15 мин").tag(15)
                        Text("30 мин").tag(30)
                        Text("60 мин").tag(60)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                LabeledContent("Глубина начальной синхронизации") {
                    Picker("", selection: $syncDepth) {
                        ForEach(SyncDepth.allCases, id: \.self) { depth in
                            Text(depth.displayName).tag(depth)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                    .onChange(of: syncDepth) { _, newValue in
                        UserDefaults.standard.set(newValue.rawValue, forKey: "syncDepth")
                    }
                }
                Text("Глубина определяет, сколько истории загружается при первом подключении аккаунта. Не влияет на уже синхронизированные папки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Кеш
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

            // MARK: Приватность
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

// MARK: - Accounts Tab (MailAi-pw2w)

private struct AccountsSettingsView: View {
    let registry: AccountRegistry?
    let secretsStore: (any SecretsStore)?

    var body: some View {
        Group {
            if let registry {
                AccountsListView(registry: registry)
            } else {
                Form {
                    Section("Аккаунты") {
                        Label("Добавьте аккаунт через приветственный экран",
                              systemImage: "person.crop.circle.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

private struct AccountsListView: View {
    @ObservedObject var registry: AccountRegistry

    var body: some View {
        HSplitView {
            // Список аккаунтов слева
            VStack(spacing: 0) {
                List(registry.accounts, id: \.id) { account in
                    HStack(spacing: 10) {
                        Image(systemName: accountIcon(account.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                                .lineLimit(1)
                            Text(accountKindLabel(account.kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 200, idealWidth: 220)

                Divider()

                HStack(spacing: 0) {
                    Spacer()
                    Text("\(registry.accounts.count) аккаунт(ов)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.bar)
            }

            // Детали справа
            Form {
                Section("Управление аккаунтами") {
                    Text("Аккаунты добавляются через кнопку «Добавить аккаунт» в приветственном окне (Файл → Новый аккаунт).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Удаление аккаунта: закройте его окно и удалите из системных настройок.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !registry.accounts.isEmpty {
                    Section("Зарегистрированные аккаунты") {
                        ForEach(registry.accounts, id: \.id) { account in
                            AccountDetailRow(account: account)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300)
        }
    }

    private func accountIcon(_ kind: Account.Kind) -> String {
        switch kind {
        case .imap:     return "server.rack"
        case .exchange: return "building.2"
        }
    }

    private func accountKindLabel(_ kind: Account.Kind) -> String {
        switch kind {
        case .imap:     return "IMAP"
        case .exchange: return "Exchange / EWS"
        }
    }
}

private struct AccountDetailRow: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.email)
                .fontWeight(.medium)
            HStack(spacing: 16) {
                LabeledContent("Сервер") {
                    Text("\(account.host):\(account.port)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if let displayName = account.displayName {
                    LabeledContent("Имя") {
                        Text(displayName)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            if let smtpHost = account.smtpHost {
                LabeledContent("SMTP") {
                    Text("\(smtpHost):\(account.smtpPort ?? 587)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Notifications Tab (MailAi-pw2w)

private struct NotificationsSettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("notifyOnlyImportant") private var notifyOnlyImportant: Bool = false
    @AppStorage("notificationSound") private var notificationSound: Bool = true
    @AppStorage("notificationBadge") private var notificationBadge: Bool = true

    var body: some View {
        Form {
            Section("Уведомления") {
                Toggle("Показывать уведомления о новых письмах", isOn: $notificationsEnabled)
            }

            if notificationsEnabled {
                Section("Фильтр") {
                    Toggle("Уведомлять только о важных письмах (AI-pack)", isOn: $notifyOnlyImportant)
                    Text("Требует включённого AI-pack. Неважные письма приходить не будут — только те, что AI отметил как важные.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Оформление") {
                    Toggle("Звук уведомления", isOn: $notificationSound)
                    Toggle("Значок на иконке (бейдж)", isOn: $notificationBadge)
                }
            }

            Section("Разрешения") {
                Text("Для получения уведомлений необходимо разрешение системы. Если уведомления не приходят — проверьте Системные настройки → Уведомления → MailAi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть настройки уведомлений") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                    )
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Signatures Tab (MailAi-8uz8)

private struct SignaturesSettingsTab: View {
    let databasePool: DatabasePool?
    let registry: AccountRegistry?

    @State private var selectedAccountID: Account.ID?

    var body: some View {
        Group {
            if let pool = databasePool {
                signaturesContent(pool: pool)
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

    @ViewBuilder
    private func signaturesContent(pool: DatabasePool) -> some View {
        VStack(spacing: 0) {
            // Per-account фильтр (если есть несколько аккаунтов)
            if let registry, registry.accounts.count > 0 {
                HStack {
                    Text("Аккаунт:")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Picker("", selection: $selectedAccountID) {
                        Text("Все").tag(Account.ID?.none)
                        ForEach(registry.accounts, id: \.id) { account in
                            Text(account.email).tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            SignaturesSettingsView(
                viewModel: SignaturesViewModel(
                    repository: SignaturesRepository(pool: pool)
                ),
                filterAccountID: selectedAccountID,
                accounts: registry?.accounts ?? []
            )
            .id(selectedAccountID) // пересоздаём VM при смене фильтра
        }
    }
}

private struct SignaturesSettingsView: View {
    @StateObject private var viewModel: SignaturesViewModel

    @State private var editingName: String = ""
    @State private var editingBody: String = ""
    @State private var editingIsDefault: Bool = false
    @State private var editingAccountID: Account.ID?

    let filterAccountID: Account.ID?
    let accounts: [Account]

    init(viewModel: SignaturesViewModel, filterAccountID: Account.ID? = nil, accounts: [Account] = []) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.filterAccountID = filterAccountID
        self.accounts = accounts
    }

    @ViewBuilder
    private var signaturesListView: some View {
        List(selection: Binding<Signature.ID?>(
            get: { viewModel.selectedID },
            set: { viewModel.selectedID = $0 }
        )) {
            ForEach(viewModel.signatures) { sig in
                HStack {
                    Text(sig.name)
                        .lineLimit(1)
                    Spacer()
                    if sig.isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                            .help("Подпись по умолчанию")
                    }
                }
                .tag(sig.id)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160, idealWidth: 180)
    }

    var body: some View {
        HSplitView {
            // MARK: Left panel — list
            VStack(spacing: 0) {
                signaturesListView

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

                        // MailAi-8uz8: привязка подписи к аккаунту
                        if !accounts.isEmpty {
                            Picker("Аккаунт", selection: $editingAccountID) {
                                Text("Все аккаунты (глобальная)").tag(Account.ID?.none)
                                ForEach(accounts, id: \.id) { account in
                                    Text(account.email).tag(Optional(account.id))
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Spacer()
                            Button("Сохранить") {
                                let name = editingName
                                let body = editingBody
                                let isDefault = editingIsDefault
                                let accountID = editingAccountID
                                Task { await viewModel.save(name: name, body: body, isDefault: isDefault,
                                                           accountID: accountID) }
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
                        editingAccountID = selected.accountID
                    }
                    .onChange(of: viewModel.selectedID) { _, _ in
                        if let s = viewModel.selected {
                            editingName = s.name
                            editingBody = s.body
                            editingIsDefault = s.isDefault
                            editingAccountID = s.accountID
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
        .task {
            viewModel.filterAccountID = filterAccountID
            await viewModel.load()
        }
        .onChange(of: filterAccountID) { _, newID in
            viewModel.filterAccountID = newID
            Task { await viewModel.load() }
        }
    }
}

// MARK: - Rules Tab (MailAi-pw2w / MailAi-vrge)

private struct RulesSettingsTab: View {
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

/// Список правил с CRUD-интерфейсом для одного аккаунта.
// MARK: - Rule Condition (MailAi-dcx9)

/// Поле условия для конструктора правил.
private enum RuleConditionField: String, CaseIterable, Identifiable {
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
private struct RulesListView: View {
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
                        // В production сохраняем новый порядок в БД через ruleEngine.reorder()
                    }
                }
            }

            // MARK: Новое правило — режим конструктора / свободный текст
            Section {
                HStack {
                    Text("Новое правило")
                        .font(.headline)
                    Spacer()
                    Button(builderMode ? "Свободный текст" : "Конструктор") {
                        builderMode.toggle()
                        // При переключении — конвертируем заполненное значение
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
                    // Конструктор: условие + действие
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

                    // Предпросмотр текста правила
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
                    // Свободный текст
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
                } // end else (free text mode)
            } // end Section

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

// MARK: - VIPSettingsTab (MailAi-tq1r)

/// Вкладка настроек: управление VIP-списком отправителей.
///
/// Показывает список VIP-адресов с возможностью добавить вручную или удалить.
private struct VIPSettingsTab: View {
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
            // Заголовок и пояснение
            VStack(alignment: .leading, spacing: 4) {
                Text("VIP-отправители")
                    .font(.headline)
                Text("Письма от VIP-отправителей всегда попадают в VIP Inbox и отображаются с звёздочкой.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Форма добавления
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

            // Список VIP
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
            // В реальном коде передавать DatabaseQueue через DI.
            // Здесь показываем заглушку — в production pool используется как reader.
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
        // В production — вызов VIPList.shared.add(email:displayName:)
        // Здесь просто обновляем локальный стейт.
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
