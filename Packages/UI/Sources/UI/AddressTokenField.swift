import SwiftUI
import AppKit

/// Поле ввода e-mail адресов с токенами (chip'ами).
///
/// Каждый введённый адрес превращается в токен при нажатии Enter, запятой
/// или точки с запятой. Backspace/Delete удаляет последний токен, если
/// поле ввода пустое. Токены можно удалить нажатием крестика на чипе.
///
/// Использование:
/// ```swift
/// AddressTokenField(tokens: $toAddresses, placeholder: "name@example.com")
/// ```
public struct AddressTokenField: View {
    @Binding public var tokens: [String]
    public var placeholder: String

    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    public init(tokens: Binding<[String]>, placeholder: String = "name@example.com") {
        self._tokens = tokens
        self.placeholder = placeholder
    }

    public var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                AddressChip(text: token) {
                    tokens.remove(at: index)
                }
            }
            InlineTextField(
                text: $inputText,
                isFocused: $isFocused,
                placeholder: tokens.isEmpty ? placeholder : "",
                onCommit: commitInput,
                onDeleteBackward: deleteLastToken
            )
            .frame(minWidth: 120)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isFocused
                        ? Color.accentColor.opacity(0.7)
                        : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .onTapGesture {
            isFocused = true
        }
    }

    // MARK: - Actions

    private func commitInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Поддерживаем ввод нескольких адресов через запятую/точку с запятой
        let parts = trimmed
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        tokens.append(contentsOf: parts)
        inputText = ""
    }

    private func deleteLastToken() {
        guard inputText.isEmpty, !tokens.isEmpty else { return }
        tokens.removeLast()
    }
}

// MARK: - AddressChip

/// Один токен-чип с крестиком для удаления.
private struct AddressChip: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.callout)
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Удалить \(text)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - InlineTextField (NSTextField wrapper)

/// NSTextField-обёртка, которая перехватывает Enter, запятую, точку с запятой
/// и Backspace для управления токенами.
private struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let placeholder: String
    let onCommit: () -> Void
    let onDeleteBackward: () -> Void

    func makeNSView(context: Context) -> TokenNSTextField {
        let field = TokenNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.delegate = context.coordinator
        field.onCommit = onCommit
        field.onDeleteBackward = onDeleteBackward
        return field
    }

    func updateNSView(_ nsView: TokenNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if isFocused, let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField

        init(parent: InlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            var value = field.stringValue
            // Запятая или точка с запятой завершают токен
            if value.contains(",") || value.contains(";") {
                value = value
                    .replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: ";", with: "")
                field.stringValue = value
                parent.text = value
                parent.onCommit()
            } else {
                parent.text = value
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               parent.text.isEmpty {
                parent.onDeleteBackward()
                return true
            }
            return false
        }
    }
}

// MARK: - TokenNSTextField

/// NSTextField с перехватом Enter и Backspace на уровне keyDown.
final class TokenNSTextField: NSTextField {
    var onCommit: (() -> Void)?
    var onDeleteBackward: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Enter (36) или NumpadEnter (76)
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        // Backspace (51) или Delete (117) при пустом поле
        if (event.keyCode == 51 || event.keyCode == 117), stringValue.isEmpty {
            onDeleteBackward?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - FlowLayout

/// Layout с переносом строк: размещает подвью горизонтально,
/// переходя на новую строку при нехватке ширины.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentY += lineHeight + spacing
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: max(currentY + lineHeight, 28))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
