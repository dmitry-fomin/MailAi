import SwiftUI
import AppKit

/// A6: NSViewRepresentable-обёртка над NSScrollView + NSHostingView. Нужна,
/// чтобы нативно обрабатывать клавиатурный скролл (Space / Shift+Space /
/// PageDown / стрелки) в зоне чтения письма. SwiftUI-`ScrollView` на macOS
/// не отдаёт такие клавиши контенту без помощи AppKit.
///
/// Содержимое передаётся как SwiftUI-вью; оно хостится через `NSHostingView`
/// и рендерится с автораскладкой по ширине NSScrollView.
public struct KeyboardScrollableReader<Content: View>: NSViewRepresentable {
    public let content: Content
    @Binding public var isFocused: Bool

    public init(isFocused: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isFocused = isFocused
        self.content = content()
    }

    public func makeNSView(context: Context) -> FocusableScrollView {
        let scroll = FocusableScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        // Flipped container, чтобы контент рос вниз — стандартное поведение
        // документ-вью текстовых/читательских областей.
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(host)

        scroll.documentView = document

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            host.topAnchor.constraint(equalTo: document.topAnchor),
            host.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        context.coordinator.hostingView = host
        context.coordinator.documentView = document
        return scroll
    }

    public func updateNSView(_ nsView: FocusableScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content
        // Ширина документ-вью = ширине clipView, чтобы SwiftUI-контент
        // мог правильно переноситься.
        if let doc = context.coordinator.documentView {
            let width = nsView.contentSize.width
            if doc.frame.width != width {
                doc.frame.size.width = width
            }
        }
        if isFocused, nsView.window?.firstResponder !== nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var hostingView: NSHostingView<Content>?
        var documentView: NSView?
    }

    /// NSScrollView, который может стать firstResponder. Нативно обрабатывает
    /// Space (pageDown), Shift+Space (pageUp), стрелки и Page Up/Down.
    public final class FocusableScrollView: NSScrollView {
        public override var acceptsFirstResponder: Bool { true }

        public override func keyDown(with event: NSEvent) {
            // Space = pageDown, Shift+Space = pageUp. NSScrollView по
            // умолчанию не реагирует на Space; пробрасываем вручную.
            if event.charactersIgnoringModifiers == " " {
                if event.modifierFlags.contains(.shift) {
                    pageUp(nil)
                } else {
                    pageDown(nil)
                }
                return
            }
            super.keyDown(with: event)
        }
    }

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }
}
