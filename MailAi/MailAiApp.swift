import SwiftUI
import AppShell

@main
struct MailAiApp: App {
    @State private var config: AppShellConfig = .init(mode: .mock)

    var body: some Scene {
        WindowGroup("MailAi") {
            ContentView(mode: config.mode)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Account Window…") {
                    // TODO: фаза A7 — открытие окна под аккаунт
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}

struct ContentView: View {
    let mode: AppShellMode

    var body: some View {
        NavigationSplitView {
            Text("Sidebar")
                .frame(minWidth: 220)
        } content: {
            Text("Список писем")
                .frame(minWidth: 320)
        } detail: {
            VStack {
                Text("Reader")
                Text("Режим: \(mode.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 480)
        }
    }
}
