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
