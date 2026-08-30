import SwiftUI

@main
struct KeyboardStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Keyboard Studio", id: "studio") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 650)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            CodexDeckMenuBarView(model: model)
        } label: {
            Label(
                "Codex Deck",
                systemImage: model.activeCodexTaskCount > 0
                    ? "bolt.horizontal.fill"
                    : (model.hasCodexAttentionWaiting ? "bell.badge.fill" : "command")
            )
        }
        .menuBarExtraStyle(.menu)
    }
}
