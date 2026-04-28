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
            self.ai = ai
        }
    }

    public let actions: Actions

    public init(actions: Actions = Actions()) {
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 4) {
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
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
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
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
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
