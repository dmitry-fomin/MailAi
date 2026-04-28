import SwiftUI
import Core

/// Набор кнопок тулбара ридера. На фазе A5 действия — no-op (плейсхолдеры);
/// реальные обработчики появятся в B7/B9 (IMAP COPY/MOVE/STORE).
public struct ReaderToolbar: View {
    // MARK: - AI Actions

    /// Действия AI Magic Menu. Все поля опциональны — nil скрывает пункт меню.
    public struct AIActions: Sendable {
        public var summarize: (@Sendable () -> Void)?
        public var quickReply: (@Sendable () -> Void)?
        public var bulkDelete: (@Sendable () -> Void)?
        public var draftCoach: (@Sendable () -> Void)?
        public var nlSearch: (@Sendable () -> Void)?
        public var attachmentSummarizer: (@Sendable () -> Void)?
        public var meetingParser: (@Sendable () -> Void)?
        public var inboxZero: (@Sendable () -> Void)?

        /// Если true — на кнопке AI показывается индикатор (AI обнаружил что-то важное).
        public var hasInsight: Bool

        public init(
            summarize: (@Sendable () -> Void)? = nil,
            quickReply: (@Sendable () -> Void)? = nil,
            bulkDelete: (@Sendable () -> Void)? = nil,
            draftCoach: (@Sendable () -> Void)? = nil,
            nlSearch: (@Sendable () -> Void)? = nil,
            attachmentSummarizer: (@Sendable () -> Void)? = nil,
            meetingParser: (@Sendable () -> Void)? = nil,
            inboxZero: (@Sendable () -> Void)? = nil,
            hasInsight: Bool = false
        ) {
            self.summarize = summarize
            self.quickReply = quickReply
            self.bulkDelete = bulkDelete
            self.draftCoach = draftCoach
            self.nlSearch = nlSearch
            self.attachmentSummarizer = attachmentSummarizer
            self.meetingParser = meetingParser
            self.inboxZero = inboxZero
            self.hasInsight = hasInsight
        }
    }

    // MARK: - Actions

    public struct Actions {
        public var reply: () -> Void
        public var replyAll: () -> Void
        public var forward: () -> Void
        public var archive: () -> Void
        public var delete: () -> Void
        public var flag: () -> Void
        public var toggleRead: () -> Void
        /// Действие «Отписаться». nil — кнопка скрыта.
        public var unsubscribe: (() -> Void)?
        /// Действие «Перевести». nil — кнопка скрыта.
        public var translate: (() -> Void)?
        /// Действие «Восстановить из Trash». nil — кнопка скрыта.
        /// MailAi-9fi0: показывается только когда письмо находится в Trash.
        public var restore: (() -> Void)?
        /// Действие «Печать». nil — кнопка скрыта.
        public var print: (() -> Void)?
        /// Действие «Snooze» с выбором времени. nil — кнопка скрыта.
        /// Принимает `Date` — время возврата письма.
        public var snooze: ((Date) -> Void)?
        /// AI-предложение snooze: дата + краткое объяснение.
        /// nil — секция «AI предлагает» не отображается.
        public var aiSnoozeSuggestion: (date: Date, reason: String)?
        /// AI Magic Menu действия. nil — кнопка AI не показывается.
        public var ai: AIActions?

        public init(
            reply: @escaping () -> Void = {},
            replyAll: @escaping () -> Void = {},
            forward: @escaping () -> Void = {},
            archive: @escaping () -> Void = {},
            delete: @escaping () -> Void = {},
            flag: @escaping () -> Void = {},
            toggleRead: @escaping () -> Void = {},
            unsubscribe: (() -> Void)? = nil,
            translate: (() -> Void)? = nil,
            restore: (() -> Void)? = nil,
            print: (() -> Void)? = nil,
            snooze: ((Date) -> Void)? = nil,
            aiSnoozeSuggestion: (date: Date, reason: String)? = nil,
            ai: AIActions? = nil
        ) {
            self.reply = reply
            self.replyAll = replyAll
            self.forward = forward
            self.archive = archive
            self.delete = delete
            self.flag = flag
            self.toggleRead = toggleRead
            self.unsubscribe = unsubscribe
            self.translate = translate
            self.restore = restore
            self.print = print
            self.snooze = snooze
            self.aiSnoozeSuggestion = aiSnoozeSuggestion
            self.ai = ai
        }
    }

    public let actions: Actions

    public init(actions: Actions = Actions()) {
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let snoozeAction = actions.snooze {
                SnoozeMenuButton(
                    onSnooze: snoozeAction,
                    aiSuggestion: actions.aiSnoozeSuggestion
                )
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
            if let unsubscribe = actions.unsubscribe {
                toolButton("hand.raised.slash", "Отписаться", action: unsubscribe)
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
            if let translate = actions.translate {
                toolButton("character.bubble", "Перевести", action: translate)
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
            toolButton("arrowshape.turn.up.left", "Ответить", action: actions.reply)
            toolButton("arrowshape.turn.up.left.2", "Ответить всем", action: actions.replyAll)
            toolButton("arrowshape.turn.up.right", "Переслать", action: actions.forward)
            Divider().frame(height: 16).padding(.horizontal, 4)
            if let restore = actions.restore {
                toolButton("arrow.uturn.backward", "Восстановить", action: restore)
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
            toolButton("archivebox", "Архив", action: actions.archive)
            toolButton("trash", "Удалить", action: actions.delete)
            toolButton("flag", "Флаг", action: actions.flag)
            toolButton("envelope.badge", "Прочитано/Непрочитано", action: actions.toggleRead)
            if let printAction = actions.print {
                Divider().frame(height: 16).padding(.horizontal, 4)
                toolButton("printer", "Печать", keyboardShortcut: "p", action: printAction)
            }
            Spacer()
            if let ai = actions.ai {
                AIMagicMenuButton(aiActions: ai)
                    .padding(.trailing, 4)
            }
            // AI-pack v1: зарезервированный слот под sync-иконку.
            // В v1 disabled и без действия; в AI-pack получит биндинг
            // «статус серверной синхронизации папок».
            aiSyncSlot
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var aiSyncSlot: some View {
        Button(action: {}) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(true)
        .help("AI-синхронизация — недоступно (включится в AI-pack)")
        .accessibilityLabel("AI-синхронизация недоступно")
    }

    @ViewBuilder
    private func toolButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 24)
                .accessibilityHidden(true) // Иконка скрыта — label на кнопке
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func toolButton(
        _ systemImage: String,
        _ label: String,
        keyboardShortcut key: Character,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 24)
                .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }
}

// MARK: - Snooze Menu Button (MailAi-f7q, MailAi-4gf)

/// Кнопка «Snooze» с выпадающим меню предустановленных времён.
/// Позволяет отложить письмо на 1 час, 3 часа, завтра утром, следующую неделю.
/// Если передан `aiSuggestion` — показывает секцию «AI предлагает» поверх стандартных вариантов.
private struct SnoozeMenuButton: View {
    let onSnooze: (Date) -> Void
    /// AI-предложение: (дата, причина). nil — секция не отображается.
    let aiSuggestion: (date: Date, reason: String)?

    init(onSnooze: @escaping (Date) -> Void, aiSuggestion: (date: Date, reason: String)? = nil) {
        self.onSnooze = onSnooze
        self.aiSuggestion = aiSuggestion
    }

    var body: some View {
        Menu {
            // MARK: AI предлагает (MailAi-4gf)
            if let suggestion = aiSuggestion {
                Section("AI предлагает") {
                    Button {
                        onSnooze(suggestion.date)
                    } label: {
                        Label(suggestion.reason, systemImage: "sparkles")
                    }
                }

                Divider()
            }

            // MARK: Стандартные варианты
            Button {
                onSnooze(snoozeDate(hoursFromNow: 1))
            } label: {
                Label("Через 1 час", systemImage: "clock")
            }

            Button {
                onSnooze(snoozeDate(hoursFromNow: 3))
            } label: {
                Label("Через 3 часа", systemImage: "clock.badge.2")
            }

            Divider()

            Button {
                onSnooze(tomorrowMorning())
            } label: {
                Label("Завтра утром (9:00)", systemImage: "sunrise")
            }

            Button {
                onSnooze(nextMonday())
            } label: {
                Label("Следующая неделя (пн 9:00)", systemImage: "calendar.badge.clock")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "moon.zzz")
                    .frame(width: 28, height: 24)
                // Индикатор — AI нашёл предложение.
                if aiSuggestion != nil {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Отложить письмо (Snooze)")
        .accessibilityLabel("Отложить письмо")
    }

    private func snoozeDate(hoursFromNow hours: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: hours, to: Date()) ?? Date()
    }

    private func tomorrowMorning() -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.day = (components.day ?? 0) + 1
        components.hour = 9
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private func nextMonday() -> Date {
        let cal = Calendar.current
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        // weekday: 1=Sun, 2=Mon, ..., 7=Sat
        let daysToMonday = weekday == 2 ? 7 : (2 - weekday + 7) % 7
        let daysToAdd = daysToMonday == 0 ? 7 : daysToMonday
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 0) + daysToAdd
        components.hour = 9
        components.minute = 0
        components.second = 0
        return cal.date(from: components) ?? Date()
    }
}

// MARK: - AI Magic Menu Button

/// Кнопка «AI ✦» с выпадающим меню всех AI-функций.
/// Показывает индикатор-точку, если `aiActions.hasInsight == true`.
private struct AIMagicMenuButton: View {
    let aiActions: ReaderToolbar.AIActions

    var body: some View {
        Menu {
            if let summarize = aiActions.summarize {
                Button(action: summarize) {
                    Label("Суммаризовать тред", systemImage: "text.quote")
                }
            }
            if let quickReply = aiActions.quickReply {
                Button(action: quickReply) {
                    Label("Быстрый ответ", systemImage: "arrowshape.turn.up.left.circle")
                }
            }
            if aiActions.summarize != nil || aiActions.quickReply != nil {
                Divider()
            }
            if let draftCoach = aiActions.draftCoach {
                Button(action: draftCoach) {
                    Label("Draft Coach", systemImage: "pencil.and.outline")
                }
            }
            if let meetingParser = aiActions.meetingParser {
                Button(action: meetingParser) {
                    Label("Найти встречу", systemImage: "calendar.badge.plus")
                }
            }
            if let attachmentSummarizer = aiActions.attachmentSummarizer {
                Button(action: attachmentSummarizer) {
                    Label("Суммаризовать вложение", systemImage: "doc.badge.gearshape")
                }
            }
            if aiActions.draftCoach != nil || aiActions.meetingParser != nil || aiActions.attachmentSummarizer != nil {
                Divider()
            }
            if let nlSearch = aiActions.nlSearch {
                Button(action: nlSearch) {
                    Label("Поиск на естественном языке", systemImage: "magnifyingglass.circle")
                }
            }
            if let bulkDelete = aiActions.bulkDelete {
                Button(action: bulkDelete) {
                    Label("Пакетное удаление", systemImage: "trash.circle")
                }
            }
            if let inboxZero = aiActions.inboxZero {
                Button(action: inboxZero) {
                    Label("Разобрать входящие (Inbox Zero)", systemImage: "tray.circle")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "sparkles")
                    .frame(width: 28, height: 24)
                if aiActions.hasInsight {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("AI функции")
        .accessibilityLabel("AI функции")
    }
}
