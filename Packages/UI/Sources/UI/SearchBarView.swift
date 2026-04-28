import SwiftUI

/// Строка поиска с анимацией раскрытия, кнопкой очистки и выбором scope.
///
/// Активируется через `isActive = true` (Cmd+F из родительского вью) или
/// нажатием на иконку лупы. При потере фокуса и пустом запросе — сворачивается.
///
/// ## Использование
/// ```swift
/// SearchBarView(
///     query: $searchVM.rawQuery,
///     scope: $searchVM.scope,
///     isActive: $searchVM.isActive,
///     onClear: { searchVM.clear() },
///     onCommit: { searchVM.commitQuery() }
/// )
/// ```
public struct SearchBarView: View {

    // MARK: - Bindings

    @Binding public var query: String
    @Binding public var scope: SearchScope
    @Binding public var isActive: Bool

    // MARK: - Callbacks

    public var onClear: () -> Void
    public var onCommit: () -> Void

    // MARK: - Private state

    @FocusState private var isFocused: Bool

    public init(
        query: Binding<String>,
        scope: Binding<SearchScope>,
        isActive: Binding<Bool>,
        onClear: @escaping () -> Void,
        onCommit: @escaping () -> Void
    ) {
        _query = query
        _scope = scope
        _isActive = isActive
        self.onClear = onClear
        self.onCommit = onCommit
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 6) {
            // Иконка лупы — кликабельна когда SearchBar свёрнут.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isActive = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            .buttonStyle(.borderless)

            if isActive {
                // Фильтр области.
                scopePicker

                // Текстовое поле.
                TextField("Поиск…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { onCommit() }
                    .onExitCommand {
                        if query.isEmpty {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isActive = false
                            }
                        } else {
                            query = ""
                            onClear()
                        }
                    }

                // Кнопка очистки.
                if !query.isEmpty {
                    Button {
                        query = ""
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .transition(.opacity)
                }

                // Кнопка закрытия.
                Button {
                    query = ""
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isActive = false
                    }
                    onClear()
                } label: {
                    Text("Отмена")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
        .onChange(of: isActive) { _, active in
            if active {
                // Небольшая задержка, чтобы TextField успел появиться.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            } else {
                isFocused = false
            }
        }
        .onAppear {
            if isActive { isFocused = true }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var scopePicker: some View {
        Picker("", selection: $scope) {
            ForEach(SearchScope.allCases, id: \.self) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// Тип scope поиска — дублируем здесь, чтобы UI не импортировал AppShell.
/// Значения должны совпадать с `SearchScope` в AppShell.
public enum SearchScope: String, CaseIterable, Sendable {
    case all     = "Везде"
    case from    = "От кого"
    case subject = "Тема"
}
