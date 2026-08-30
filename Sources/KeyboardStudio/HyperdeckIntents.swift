import AppIntents
import Foundation

@MainActor
enum HyperdeckIntentBridge {
    static weak var controller: HyperdeckController?

    static func install(controller: HyperdeckController) {
        self.controller = controller
    }

    static func acknowledgeCodex() async {
        await controller?.onAcknowledgeCodex?()
    }
}

struct RunHyperdeckRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Keyboard Studio Recipe"
    static let description = IntentDescription("Runs a named multi-action recipe configured in Keyboard Studio.")
    static let openAppWhenRun = false

    @Parameter(title: "Recipe Name")
    var recipeName: String

    init() {}

    init(recipeName: String) {
        self.recipeName = recipeName
    }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            guard let controller = HyperdeckIntentBridge.controller else {
                throw HyperdeckExecutionError.recipeNotFound
            }
            try controller.execute(recipeNamed: recipeName)
        }
        return .result()
    }
}

struct ToggleHyperdeckFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Keyboard Studio Focus Timer"
    static let description = IntentDescription("Starts or pauses the Keyboard Studio focus timer.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { HyperdeckIntentBridge.controller?.toggleFocus() }
        return .result()
    }
}

struct ResetHyperdeckFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Keyboard Studio Focus Timer"
    static let description = IntentDescription("Resets the Keyboard Studio focus timer to its configured duration.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { HyperdeckIntentBridge.controller?.resetFocus() }
        return .result()
    }
}

struct AcknowledgeCodexIntent: AppIntent {
    static let title: LocalizedStringResource = "Acknowledge Codex Activity"
    static let description = IntentDescription("Marks the current Codex activity caught up and clears the attention lamp.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await HyperdeckIntentBridge.acknowledgeCodex()
        return .result()
    }
}
