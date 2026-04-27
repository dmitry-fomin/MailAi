import SwiftUI
import UniformTypeIdentifiers
import Core
import AI

/// AI-5: Transferable-репрезентация письма для drag-to-rule.
///
/// Тащим только метаданные, по которым строится правило — никакого
/// тела/snippet'а. Адрес отправителя нужен для шаблона `from:…`,
/// `subject` — для `subject contains: …`.
public struct DraggableMessage: Codable, Hashable, Sendable, Transferable {
    public let id: String
    public let from: String?
    public let fromName: String?
    public let subject: String

    public init(id: String, from: String?, fromName: String?, subject: String) {
        self.id = id
        self.from = from
        self.fromName = fromName
        self.subject = subject
    }

    public init(message: Message) {
        self.id = message.id.rawValue
        self.from = message.from?.address
        self.fromName = message.from?.name
        self.subject = message.subject
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mailAiDraggedMessage)
    }
}

extension UTType {
    /// Custom UTI для drag&drop писем внутри окна аккаунта.
    public static var mailAiDraggedMessage: UTType {
        UTType(exportedAs: "ai.mailai.message")
    }
}

/// AI-5: лист подтверждения правила, открываемый после drag письма
/// на «Неважно» / «Важное».
@MainActor
public struct RuleProposalSheet: View {
    public enum Mode: Sendable {
        case markUnimportant
        case markImportant

        var intent: Rule.Intent {
            switch self {
            case .markImportant: return .markImportant
            case .markUnimportant: return .markUnimportant
            }
        }

        var title: String {
            switch self {
            case .markImportant: return "Создать правило «Важное»?"
            case .markUnimportant: return "Создать правило «Неважно»?"
            }
        }
    }

    public enum Template: Hashable, Sendable {
        case fromSender
        case subjectContains
    }

    let messages: [DraggableMessage]
    let mode: Mode
    let onConfirm: @MainActor (Rule) async -> Void
    let onCancel: @MainActor () -> Void

    @State private var selectedTemplate: Template = .fromSender

    public init(
        messages: [DraggableMessage],
        mode: Mode,
        onConfirm: @escaping @MainActor (Rule) async -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.messages = messages
        self.mode = mode
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title)
                .font(.title3.bold())

            if let summary = previewSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Шаблон", selection: $selectedTemplate) {
                if hasFrom {
                    Text("По отправителю").tag(Template.fromSender)
                }
                if hasSubject {
                    Text("По теме").tag(Template.subjectContains)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!hasFrom || !hasSubject)

            GroupBox(label: Text("Текст правила").font(.caption)) {
                Text(currentRuleText)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Отмена", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Создать правило") {
                    let rule = Rule(
                        text: currentRuleText,
                        intent: mode.intent,
                        source: .dragConfirm
                    )
                    Task { await onConfirm(rule) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(currentRuleText.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 440)
        .onAppear {
            // Если from недоступен — стартуем с темы.
            if !hasFrom { selectedTemplate = .subjectContains }
        }
    }

    private var hasFrom: Bool {
        messages.contains(where: { ($0.from?.isEmpty == false) })
    }

    private var hasSubject: Bool {
        messages.contains(where: { !$0.subject.isEmpty })
    }

    private var previewSummary: String? {
        if messages.count > 1 {
            return "Применить к \(messages.count) письмам"
        }
        return nil
    }

    /// Генерирует NL-правило для классификатора.
    private var currentRuleText: String {
        switch selectedTemplate {
        case .fromSender:
            let senders = messages.compactMap { $0.from }.filter { !$0.isEmpty }
            let unique = Array(Set(senders))
            switch mode {
            case .markUnimportant:
                return "Считать неважными письма от: \(unique.joined(separator: ", "))"
            case .markImportant:
                return "Считать важными письма от: \(unique.joined(separator: ", "))"
            }
        case .subjectContains:
            let subjects = messages.map { $0.subject }.filter { !$0.isEmpty }
            let unique = Array(Set(subjects))
            switch mode {
            case .markUnimportant:
                return "Считать неважными письма с темой, содержащей: \(unique.joined(separator: " | "))"
            case .markImportant:
                return "Считать важными письма с темой, содержащей: \(unique.joined(separator: " | "))"
            }
        }
    }
}
