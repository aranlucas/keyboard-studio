import AppKit
import SwiftUI

struct CodexDeckMenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.activeCodexTaskCount > 0
            ? "Codex Deck · \(model.activeCodexTaskCount) working"
            : (model.hasCodexAttentionWaiting ? "Codex Deck · attention" : "Codex Deck · caught up"))

        Divider()

        Button("Show Keyboard Studio") {
            openWindow(id: "studio")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Button("Open Codex · F13") {
            model.openCodex()
        }

        Button("Clear alerts · F16") {
            Task { await model.acknowledgeCodexDeck() }
        }

        Divider()

        Text(model.isCodexDeckInstalled ? "Layer 1 installed" : "Layer 1 not installed")
        Text(model.keyboardAccessStatus == .granted ? "Keyboard connected" : "Keyboard access needed")

        if model.keyboardAccessStatus != .granted {
            Button("Open Input Monitoring") {
                Task { await model.requestKeyboardAccess() }
            }
            Button("Restart Keyboard Studio") {
                model.restartApplication()
            }
        }

        Divider()

        Button("Quit Keyboard Studio") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
