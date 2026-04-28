import SwiftUI
import Core

/// Набор кнопок тулбара ридера. На фазе A5 действия — no-op (плейсхолдеры);
/// реальные обработчики появятся в B7/B9 (IMAP COPY/MOVE/STORE).
public struct ReaderToolbar: View {
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
            restore: (() -> Void)? = nil
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
            Spacer()
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
}
