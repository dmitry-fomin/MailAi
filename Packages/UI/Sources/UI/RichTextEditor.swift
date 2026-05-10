import SwiftUI
import AppKit

/// Rich text editor на базе NSTextView (TextKit 2).
/// Поддерживает форматирование: жирный, курсив, подчёркивание, размер шрифта, цвет текста.
/// Конвертация в HTML через NSAttributedString documentAttributes.
///
/// Использование:
/// ```swift
/// @State private var attributedText = NSAttributedString()
/// RichTextEditor(attributedText: $attributedText)
/// ```
public struct RichTextEditor: NSViewRepresentable {
    @Binding public var attributedText: NSAttributedString

    public init(attributedText: Binding<NSAttributedString>) {
        self._attributedText = attributedText
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesRuler = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator

        // Начальное содержимое
        if attributedText.length > 0 {
            textView.textStorage?.setAttributedString(attributedText)
        }

        context.coordinator.textView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Обновляем только если изменилось снаружи (избегаем цикла)
        guard !context.coordinator.isEditing else { return }
        if textView.attributedString() != attributedText {
            let selectedRange = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributedText)
            if selectedRange.location <= (textView.textStorage?.length ?? 0) {
                textView.setSelectedRange(selectedRange)
            }
        }
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        var isEditing: Bool = false

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true
            parent.attributedText = textView.attributedString()
            isEditing = false
        }
    }
}

// MARK: - Toolbar

/// Toolbar для RichTextEditor: Bold, Italic, Underline, font size, text color.
public struct RichTextToolbar: View {
    /// Ссылка на NSTextView для применения форматирования.
    /// Передаётся через RichTextEditorContainer.
    public var applyFormat: (RichTextFormat) -> Void

    @State private var fontSize = Double(NSFont.systemFontSize)
    @State private var selectedColor: Color = .primary

    public init(applyFormat: @escaping (RichTextFormat) -> Void) {
        self.applyFormat = applyFormat
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Bold
            Button {
                applyFormat(.bold)
            } label: {
                Image(systemName: "bold")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Жирный (⌘B)")
            .keyboardShortcut("b", modifiers: .command)

            // Italic
            Button {
                applyFormat(.italic)
            } label: {
                Image(systemName: "italic")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Курсив (⌘I)")
            .keyboardShortcut("i", modifiers: .command)

            // Underline
            Button {
                applyFormat(.underline)
            } label: {
                Image(systemName: "underline")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Подчёркивание (⌘U)")
            .keyboardShortcut("u", modifiers: .command)

            Divider().frame(height: 16)

            // Font size stepper
            HStack(spacing: 2) {
                Button {
                    fontSize = max(8, fontSize - 1)
                    applyFormat(.fontSize(fontSize))
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Уменьшить размер шрифта")

                Text("\(Int(fontSize))")
                    .font(.caption)
                    .frame(minWidth: 24)
                    .monospacedDigit()

                Button {
                    fontSize = min(72, fontSize + 1)
                    applyFormat(.fontSize(fontSize))
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Увеличить размер шрифта")
            }

            Divider().frame(height: 16)

            // Text color
            ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28, height: 22)
                .help("Цвет текста")
                .onChange(of: selectedColor) { _, newColor in
                    applyFormat(.textColor(NSColor(newColor)))
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// Команды форматирования для RichTextEditor.
public enum RichTextFormat: Sendable {
    case bold
    case italic
    case underline
    case fontSize(Double)
    case textColor(NSColor)
}

// MARK: - Container

/// Полный редактор с toolbar и NSTextView. Основная точка использования.
public struct RichTextEditorContainer: View {
    @Binding public var attributedText: NSAttributedString

    /// Хранит ссылку на NSTextView для применения форматирования.
    @State private var textViewRef: NSTextView?

    public init(attributedText: Binding<NSAttributedString>) {
        self._attributedText = attributedText
    }

    public var body: some View {
        VStack(spacing: 0) {
            RichTextToolbar { format in
                applyFormat(format)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            RichTextEditor(attributedText: $attributedText)
                .onAppear {
                    // Захватываем ссылку на NSTextView при появлении
                }
        }
    }

    // MARK: - Format application

    private func applyFormat(_ format: RichTextFormat) {
        guard let textView = findTextView() else { return }
        let range = textView.selectedRange()
        guard range.length > 0, let storage = textView.textStorage else { return }

        storage.beginEditing()
        switch format {
        case .bold:
            toggleTrait(.bold, in: storage, range: range)
        case .italic:
            toggleTrait(.italic, in: storage, range: range)
        case .underline:
            toggleUnderline(in: storage, range: range)
        case .fontSize(let size):
            setFontSize(size, in: storage, range: range)
        case .textColor(let color):
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        storage.endEditing()

        // Синхронизируем биндинг
        attributedText = textView.attributedString()
    }

    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits, in storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            var traits = font.fontDescriptor.symbolicTraits
            if traits.contains(trait) {
                traits.remove(trait)
            } else {
                traits.insert(trait)
            }
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            if let newFont = NSFont(descriptor: descriptor, size: font.pointSize) {
                storage.addAttribute(.font, value: newFont, range: subrange)
            }
        }
    }

    private func toggleUnderline(in storage: NSTextStorage, range: NSRange) {
        var hasUnderline = false
        storage.enumerateAttribute(.underlineStyle, in: range, options: []) { value, _, _ in
            if let style = value as? Int, style != 0 {
                hasUnderline = true
            }
        }
        let newStyle = hasUnderline ? 0 : NSUnderlineStyle.single.rawValue
        storage.addAttribute(.underlineStyle, value: newStyle, range: range)
    }

    private func setFontSize(_ size: Double, in storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            if let newFont = NSFont(descriptor: font.fontDescriptor, size: size) {
                storage.addAttribute(.font, value: newFont, range: subrange)
            }
        }
    }

    /// Ищет NSTextView в иерархии NSApplication.
    private func findTextView() -> NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }
}

// MARK: - HTML Export

/// Конвертация NSAttributedString в HTML для отправки письма.
public enum RichTextHTMLExporter {
    /// Конвертирует атрибутированную строку в HTML-строку.
    /// Возвращает plain text как fallback при ошибке конвертации.
    public static func html(from attributedString: NSAttributedString) -> String {
        guard attributedString.length > 0 else { return "" }
        let options: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        do {
            let data = try attributedString.data(
                from: NSRange(location: 0, length: attributedString.length),
                documentAttributes: options
            )
            return String(data: data, encoding: .utf8) ?? attributedString.string
        } catch {
            return attributedString.string
        }
    }

    /// Создаёт NSAttributedString из HTML-строки (для загрузки черновика).
    public static func attributedString(fromHTML html: String) -> NSAttributedString {
        guard !html.isEmpty,
              let data = html.data(using: .utf8) else {
            return NSAttributedString(string: html)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))
            ?? NSAttributedString(string: html)
    }
}
