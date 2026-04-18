import SwiftUI

/// Настройки приложения. В v1 содержит только каркас раздела «Отфильтрованные»
/// с placeholder-ом «AI-классификация — недоступно». Реальные поля (ключ
/// OpenRouter, модель, retention, правила) появятся с AI-pack.
public struct SettingsScene: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Общие", systemImage: "gearshape") }
            FilteredSettingsView()
                .tabItem { Label("Отфильтрованные", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section("Аккаунты") {
                Text("Управление аккаунтами — через первое окно (Welcome).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FilteredSettingsView: View {
    var body: some View {
        Form {
            Section("AI-классификация") {
                Label("AI-классификация — недоступно", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                Text("Раздел появится с AI-pack. Вы сможете указать OpenRouter-ключ, выбрать модель и сформулировать NL-правила для автоматической сортировки почты.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
