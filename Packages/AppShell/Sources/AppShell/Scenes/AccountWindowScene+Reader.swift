import SwiftUI
import AppKit
import Core
import UI
import AI

extension AccountWindowScene {

    // MARK: - Reader

    @ViewBuilder var reader: some View {
        if let body = session.openBody, let message = selectedMessage {
            VStack(alignment: .leading, spacing: 0) {
                ReaderHeaderView(message: message)
                ReaderToolbar(actions: ReaderToolbar.Actions(
                    reply: {
                        guard let msg = selectedMessage else { return }
                        composeRequest = ComposeRequest(model: ComposeViewModel.makeReply(
                            to: msg,
                            accountEmail: session.account.email,
                            accountDisplayName: session.account.displayName,
                            sendProvider: session.provider as? any SendProvider,
                            draftSaver: nil
                        ))
                    },
                    replyAll: {
                        guard let msg = selectedMessage else { return }
                        composeRequest = ComposeRequest(model: ComposeViewModel.makeReplyAll(
                            to: msg,
                            accountEmail: session.account.email,
                            accountDisplayName: session.account.displayName,
                            sendProvider: session.provider as? any SendProvider,
                            draftSaver: nil
                        ))
                    },
                    forward: {
                        guard let msg = selectedMessage else { return }
                        composeRequest = ComposeRequest(model: ComposeViewModel.makeForward(
                            of: msg,
                            accountEmail: session.account.email,
                            accountDisplayName: session.account.displayName,
                            sendProvider: session.provider as? any SendProvider,
                            draftSaver: nil
                        ))
                    },
                    archive: { Task { await session.perform(.archive) } },
                    delete: { showDeleteConfirmation = true },
                    flag: { Task { await session.perform(.toggleFlag) } },
                    toggleRead: { Task { await session.perform(.toggleRead) } },
                    unsubscribe: message.listUnsubscribe != nil
                        ? { showUnsubscribeConfirm = true }
                        : nil,
                    translate: translator != nil
                        ? { Task { await performTranslation(body: body) } }
                        : nil,
                    // MailAi-9fi0: кнопка «Восстановить» видна только в Trash.
                    restore: session.isInTrash
                        ? {
                            guard let id = session.selectedMessageID else { return }
                            Task { await session.restore(messageIDs: [id]) }
                        }
                        : nil
                ))
                .confirmationDialog("Отписаться от рассылки?", isPresented: $showUnsubscribeConfirm) {
                    Button("Отписаться", role: .destructive) {
                        Task { await showToast("Запрос на отписку отправлен") }
                    }
                    Button("Отмена", role: .cancel) {}
                }
                Divider()
                if translatedBody != nil {
                    Picker("", selection: $showTranslation) {
                        Text("Оригинал").tag(false)
                        Text("Перевод").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                if isTranslating {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Перевод…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                if showTranslation, let translation = translatedBody {
                    let translatedBody = MessageBody(
                        messageID: body.messageID,
                        content: .plain(translation.text),
                        attachments: body.attachments
                    )
                    ReaderBodyView(
                        body: translatedBody,
                        messageID: translatedBody.messageID.rawValue,
                        cacheManager: cacheManager,
                        onSaveAttachment: { att in saveAttachment(att) },
                        isFocused: Binding(
                            get: { focus == .reader },
                            set: { newValue in if newValue { focus = .reader } }
                        )
                    )
                } else {
                    ReaderBodyView(
                        body: body,
                        messageID: body.messageID.rawValue,
                        cacheManager: cacheManager,
                        onSaveAttachment: { att in saveAttachment(att) },
                        isFocused: Binding(
                            get: { focus == .reader },
                            set: { newValue in if newValue { focus = .reader } }
                        )
                    )
                }
            }
            .onChange(of: session.selectedMessageID) { _, _ in
                translatedBody = nil
                showTranslation = false
                isTranslating = false
            }
            // MailAi-k90l: регистрируем NSUserActivity для Spotlight.
            .userActivity("com.mailai.message", isActive: true) { activity in
                activity.title = message.subject.isEmpty ? "(Без темы)" : message.subject
                activity.userInfo = [
                    "messageID": message.id.rawValue,
                    "accountID": session.account.id.rawValue
                ]
                activity.isEligibleForSearch = true
                activity.isEligibleForHandoff = false
                activity.isEligibleForPublicIndexing = false
            }
        } else if session.openBody == nil && session.isOffline && session.selectedMessageID != nil {
            ContentUnavailableView(
                "Тело письма недоступно офлайн",
                systemImage: "wifi.slash",
                description: Text("Подключитесь к интернету, чтобы загрузить письмо.")
            )
        } else {
            ContentUnavailableView(
                "Выберите письмо",
                systemImage: "envelope",
                description: Text("Кликните по строке в списке, чтобы открыть содержимое.")
            )
        }
    }

    @MainActor
    func performTranslation(body: MessageBody) async {
        guard let translator else { return }
        guard !isTranslating else { return }
        let text: String
        switch body.content {
        case .plain(let s): text = s
        case .html(let h):
            let data = Data(h.utf8)
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            text = (try? NSAttributedString(data: data, options: opts, documentAttributes: nil))?.string ?? h
        }
        guard !text.isEmpty else { return }
        isTranslating = true
        defer { isTranslating = false }
        do {
            let result: MailTranslation = try await translator.translate(body: text, targetLanguage: "ru")
            translatedBody = result
            showTranslation = true
        } catch {
            await showToast("Не удалось перевести письмо")
        }
    }

    @MainActor
    func saveAttachment(_ attachment: Attachment) {
        Task {
            do {
                let data = try await session.downloadAttachment(attachment)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.filename.isEmpty ? "attachment" : attachment.filename
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url)
            } catch {
                await showToast("Не удалось скачать вложение")
            }
        }
    }

    var selectedMessage: Message? {
        guard let id = session.selectedMessageID else { return nil }
        return session.messages.first(where: { $0.id == id })
            ?? session.searchResults.first(where: { $0.id == id })
    }
}
