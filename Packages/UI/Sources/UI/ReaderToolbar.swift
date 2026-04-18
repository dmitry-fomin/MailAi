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

        public init(
            reply: @escaping () -> Void = {},
            replyAll: @escaping () -> Void = {},
            forward: @escaping () -> Void = {},
            archive: @escaping () -> Void = {},
            delete: @escaping () -> Void = {},
            flag: @escaping () -> Void = {}
        ) {
            self.reply = reply
            self.replyAll = replyAll
            self.forward = forward
            self.archive = archive
            self.delete = delete
            self.flag = flag
        }
    }

    public let actions: Actions

    public init(actions: Actions = Actions()) {
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 4) {
            toolButton("arrowshape.turn.up.left", "Ответить", action: actions.reply)
            toolButton("arrowshape.turn.up.left.2", "Ответить всем", action: actions.replyAll)
            toolButton("arrowshape.turn.up.right", "Переслать", action: actions.forward)
            Divider().frame(height: 16).padding(.horizontal, 4)
            toolButton("archivebox", "Архив", action: actions.archive)
            toolButton("trash", "Удалить", action: actions.delete)
            toolButton("flag", "Флаг", action: actions.flag)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
