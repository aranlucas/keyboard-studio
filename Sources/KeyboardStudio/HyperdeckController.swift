import AppKit
import Combine
import Foundation
import KeyboardCore
import OSLog

struct HyperdeckRuntimeEvent: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let detail: String
    let isError: Bool
}

struct HyperdeckClipboardItem: Identifiable, Equatable {
    let id = UUID()
    let capturedAt: Date
    var text: String
}

struct HyperdeckFocusState: Equatable {
    var total: TimeInterval
    var remaining: TimeInterval
    var isRunning: Bool
    var completedSessions: Int

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }
}

enum HyperdeckClipboardTransform: String, CaseIterable, Identifiable {
    case trim
    case uppercase
    case lowercase
    case singleLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trim: "Trim"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .singleLine: "Single line"
        }
    }
}

enum HyperdeckExecutionError: Error, LocalizedError {
    case invalidURL(String)
    case applicationNotFound(String)
    case executableNotApproved(String)
    case recipeNotFound

    var errorDescription: String? {
        switch self {
        case let .invalidURL(value): "Invalid URL: \(value)"
        case let .applicationNotFound(value): "Application not found: \(value)"
        case let .executableNotApproved(value): "Executable is unavailable or not executable: \(value)"
        case .recipeNotFound: "The assigned recipe no longer exists."
        }
    }
}

@MainActor
final class HyperdeckController: ObservableObject {
    @Published private(set) var configuration: HyperdeckConfiguration
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var activeApplicationName = "Everywhere"
    @Published private(set) var activeBundleIdentifier = ""
    @Published private(set) var runtimeEvents: [HyperdeckRuntimeEvent] = []
    @Published private(set) var clipboardItems: [HyperdeckClipboardItem] = []
    @Published var selectedClipboardIndex = 0
    @Published private(set) var focusState: HyperdeckFocusState
    @Published private(set) var isListening = false
    @Published private(set) var statusMessage = "Hyperdeck is ready."
    @Published var selectedProfileID: UUID?
    @Published var selectedRecipeID: UUID?

    var onOpenCodex: (() async -> Void)?
    var onAcknowledgeCodex: (() async -> Void)?
    var onNextCodexReview: (() async -> Void)?
    var onShowStudio: (() async -> Void)?
    var onNotification: ((String, String) async -> Void)?
    var onRGB: ((HyperdeckRGBColor) async -> Void)?
    var onProfileChanged: ((HyperdeckProfile) async -> Void)?
    var onFocusChanged: ((HyperdeckFocusState) async -> Void)?
    var onPhysicalEvent: ((HyperdeckPhysicalEvent) -> Void)?

    private var recognizer: HyperdeckGestureRecognizer
    private var hotKeyController: HyperdeckHotKeyController?
    private var gestureTickTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var focusEndsAt: Date?
    private var lastPublishedFocusSecond: Int?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var hasStarted = false

    private static let configurationKey = "hyperdeckConfigurationV1"
    private static let logger = Logger(subsystem: "com.lucas.keyboardstudio", category: "Hyperdeck")

    init(defaults: UserDefaults = .standard) {
        let loadedConfiguration: HyperdeckConfiguration
        if let data = defaults.data(forKey: Self.configurationKey),
           let decoded = try? JSONDecoder().decode(HyperdeckConfiguration.self, from: data),
           decoded.format == "Keyboard Studio Hyperdeck 1.0"
        {
            loadedConfiguration = decoded
        } else {
            loadedConfiguration = .defaults
        }
        configuration = loadedConfiguration
        recognizer = HyperdeckGestureRecognizer(timing: loadedConfiguration.timing)
        let seconds = TimeInterval(max(1, loadedConfiguration.focusMinutes) * 60)
        focusState = HyperdeckFocusState(total: seconds, remaining: seconds, isRunning: false, completedSessions: 0)
        selectedProfileID = loadedConfiguration.profiles.first?.id
        selectedRecipeID = loadedConfiguration.recipes.first?.id
    }

    isolated deinit {
        gestureTickTask?.cancel()
        clipboardTask?.cancel()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            hotKeyController = try HyperdeckHotKeyController { [weak self] event in
                self?.receive(event)
            }
            isListening = true
            statusMessage = "Listening for F13/F16 press and release events."
        } catch {
            isListening = false
            statusMessage = error.localizedDescription
            record("Hot keys unavailable", detail: error.localizedDescription, isError: true)
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.activate(application) }
        }
        if let application = NSWorkspace.shared.frontmostApplication {
            activate(application)
        }

        gestureTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.process(self.recognizer.flush(at: now))
                await self.updateFocusClock()
            }
        }
        synchronizeClipboardMonitoring()
    }

    func receive(_ event: HyperdeckPhysicalEvent) {
        onPhysicalEvent?(event)
        let label = event.key == .left ? "F13" : "F16"
        record(
            "\(label) \(event.phase == .down ? "pressed" : "released")",
            detail: "Physical \(event.key.title.lowercased()) event received."
        )
        Self.logger.notice(
            "Physical key=\(event.key.rawValue, privacy: .public) phase=\(event.phase.rawValue, privacy: .public)"
        )
        process(recognizer.handle(event))
    }

    func replaceConfiguration(_ configuration: HyperdeckConfiguration) {
        var configuration = configuration
        configuration.timing.normalize()
        configuration.focusMinutes = min(max(configuration.focusMinutes, 1), 180)
        self.configuration = configuration
        recognizer.updateTiming(configuration.timing)
        if !configuration.profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = configuration.profiles.first?.id
        }
        if !configuration.recipes.contains(where: { $0.id == selectedRecipeID }) {
            selectedRecipeID = configuration.recipes.first?.id
        }
        persistConfiguration()
        synchronizeClipboardMonitoring()
        resolveActiveProfile()
    }

    func updateTiming(_ timing: HyperdeckGestureTiming) {
        var updated = configuration
        updated.timing = timing
        replaceConfiguration(updated)
    }

    func updateProfile(_ profile: HyperdeckProfile) {
        var updated = configuration
        if let index = updated.profiles.firstIndex(where: { $0.id == profile.id }) {
            updated.profiles[index] = profile
        } else {
            updated.profiles.append(profile)
        }
        replaceConfiguration(updated)
        selectedProfileID = profile.id
    }

    func deleteProfile(id: UUID) {
        var updated = configuration
        guard updated.profiles.count > 1 else {
            statusMessage = "Hyperdeck needs at least one fallback profile."
            return
        }
        updated.profiles.removeAll { $0.id == id }
        replaceConfiguration(updated)
    }

    func updateRecipe(_ recipe: HyperdeckRecipe) {
        var updated = configuration
        if let index = updated.recipes.firstIndex(where: { $0.id == recipe.id }) {
            updated.recipes[index] = recipe
        } else {
            updated.recipes.append(recipe)
        }
        replaceConfiguration(updated)
        selectedRecipeID = recipe.id
    }

    func deleteRecipe(id: UUID) {
        var updated = configuration
        updated.recipes.removeAll { $0.id == id }
        for index in updated.profiles.indices {
            updated.profiles[index].assignments = updated.profiles[index].assignments.filter { $0.value != id }
        }
        replaceConfiguration(updated)
    }

    func resetDefaults() {
        replaceConfiguration(.defaults)
        resetFocus()
        statusMessage = "Hyperdeck defaults restored."
    }

    func testGesture(_ gesture: HyperdeckGesture) {
        process([gesture])
    }

    func execute(recipeID: UUID) {
        guard let recipe = configuration.recipes.first(where: { $0.id == recipeID }) else {
            record("Recipe failed", detail: HyperdeckExecutionError.recipeNotFound.localizedDescription, isError: true)
            return
        }
        Task { [weak self] in await self?.execute(recipe) }
    }

    func execute(recipeNamed name: String) throws {
        guard let recipe = configuration.recipes.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw HyperdeckExecutionError.recipeNotFound
        }
        execute(recipeID: recipe.id)
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "keyboardstudio" else { return }
        switch url.host {
        case "toggle-focus": toggleFocus()
        case "reset-focus": resetFocus()
        case "acknowledge-codex":
            Task { [weak self] in await self?.onAcknowledgeCodex?() }
        case "run-recipe":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let identifier = components?.queryItems?.first(where: { $0.name == "id" })?.value
            let name = components?.queryItems?.first(where: { $0.name == "name" })?.value
            if let identifier, let id = UUID(uuidString: identifier) {
                execute(recipeID: id)
            } else if let name,
                      let recipe = configuration.recipes.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
            {
                execute(recipeID: recipe.id)
            } else {
                record("Deep link failed", detail: "Recipe was not found.", isError: true)
            }
        default:
            statusMessage = "Unsupported Keyboard Studio link: \(url.absoluteString)"
        }
    }

    func setClipboardMonitoring(_ enabled: Bool) {
        var updated = configuration
        updated.clipboardMonitoringEnabled = enabled
        replaceConfiguration(updated)
    }

    func selectPreviousClipboardItem() {
        guard !clipboardItems.isEmpty else {
            statusMessage = "Clipboard Deck has no captured text yet."
            return
        }
        selectedClipboardIndex = (selectedClipboardIndex - 1 + clipboardItems.count) % clipboardItems.count
        statusMessage = "Selected clipboard item \(selectedClipboardIndex + 1) of \(clipboardItems.count)."
    }

    func selectNextClipboardItem() {
        guard !clipboardItems.isEmpty else {
            statusMessage = "Clipboard Deck has no captured text yet."
            return
        }
        selectedClipboardIndex = (selectedClipboardIndex + 1) % clipboardItems.count
        statusMessage = "Selected clipboard item \(selectedClipboardIndex + 1) of \(clipboardItems.count)."
    }

    func copySelectedClipboardItem() {
        guard clipboardItems.indices.contains(selectedClipboardIndex) else {
            statusMessage = "Select a clipboard item first."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardItems[selectedClipboardIndex].text, forType: .string)
        lastPasteboardChangeCount = pasteboard.changeCount
        statusMessage = "Selected item copied. Paste it normally with Command–V."
        record("Clipboard selection copied", detail: "No synthetic paste event was sent.")
    }

    func transformSelectedClipboardItem(_ transform: HyperdeckClipboardTransform) {
        guard clipboardItems.indices.contains(selectedClipboardIndex) else { return }
        let original = clipboardItems[selectedClipboardIndex].text
        clipboardItems[selectedClipboardIndex].text = switch transform {
        case .trim: original.trimmingCharacters(in: .whitespacesAndNewlines)
        case .uppercase: original.uppercased()
        case .lowercase: original.lowercased()
        case .singleLine: original.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        statusMessage = "Applied \(transform.title) to the selected in-memory item."
    }

    func clearClipboardHistory() {
        clipboardItems.removeAll()
        selectedClipboardIndex = 0
        statusMessage = "In-memory Clipboard Deck history cleared."
    }

    func setFocusMinutes(_ minutes: Int) {
        var updated = configuration
        updated.focusMinutes = min(max(minutes, 1), 180)
        replaceConfiguration(updated)
        resetFocus()
    }

    func toggleFocus() {
        if focusState.isRunning {
            if let focusEndsAt {
                focusState.remaining = max(0, focusEndsAt.timeIntervalSinceNow)
            }
            focusState.isRunning = false
            focusEndsAt = nil
            statusMessage = "Focus timer paused."
        } else {
            if focusState.remaining <= 0 { resetFocus() }
            focusState.isRunning = true
            focusEndsAt = Date().addingTimeInterval(focusState.remaining)
            statusMessage = "Focus session started."
        }
        lastPublishedFocusSecond = nil
        Task { [state = focusState, weak self] in await self?.onFocusChanged?(state) }
        record("Focus timer \(focusState.isRunning ? "started" : "paused")", detail: formattedFocusTime)
    }

    func resetFocus() {
        let seconds = TimeInterval(max(1, configuration.focusMinutes) * 60)
        focusState.total = seconds
        focusState.remaining = seconds
        focusState.isRunning = false
        focusEndsAt = nil
        lastPublishedFocusSecond = nil
        statusMessage = "Focus timer reset to \(configuration.focusMinutes) minutes."
        Task { [state = focusState, weak self] in await self?.onFocusChanged?(state) }
    }

    var formattedFocusTime: String {
        let seconds = max(0, Int(focusState.remaining.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var activeProfile: HyperdeckProfile? {
        configuration.profiles.first(where: { $0.id == activeProfileID })
    }

    var selectedClipboardItem: HyperdeckClipboardItem? {
        guard clipboardItems.indices.contains(selectedClipboardIndex) else { return nil }
        return clipboardItems[selectedClipboardIndex]
    }

    private func process(_ gestures: [HyperdeckGesture]) {
        for gesture in gestures {
            guard let profile = activeProfile,
                  let recipeID = configuration.recipeID(for: gesture, profileID: profile.id),
                  let recipe = configuration.recipes.first(where: { $0.id == recipeID })
            else {
                record(gesture.title, detail: "No recipe assigned in \(activeProfile?.name ?? "the active profile").")
                continue
            }
            record(gesture.title, detail: "Running “\(recipe.name)” in \(profile.name).")
            Self.logger.notice(
                "Gesture=\(gesture.rawValue, privacy: .public) profile=\(profile.name, privacy: .public) recipe=\(recipe.name, privacy: .public)"
            )
            Task { [weak self] in await self?.execute(recipe) }
        }
    }

    private func execute(_ recipe: HyperdeckRecipe) async {
        statusMessage = "Running \(recipe.name)…"
        do {
            for step in recipe.steps {
                try Task.checkCancellation()
                try await execute(step)
            }
            statusMessage = "Finished \(recipe.name)."
            record("Recipe completed", detail: recipe.name)
        } catch is CancellationError {
            statusMessage = "Cancelled \(recipe.name)."
        } catch {
            statusMessage = "\(recipe.name) failed: \(error.localizedDescription)"
            record("Recipe failed", detail: statusMessage, isError: true)
        }
    }

    private func execute(_ step: HyperdeckActionStep) async throws {
        switch step.kind {
        case .none:
            return
        case .openApplication:
            let workspace = NSWorkspace.shared
            let appURL: URL?
            if step.value.hasPrefix("/") {
                appURL = URL(filePath: step.value)
            } else {
                appURL = workspace.urlForApplication(withBundleIdentifier: step.value)
            }
            guard let appURL, FileManager.default.fileExists(atPath: appURL.path) else {
                throw HyperdeckExecutionError.applicationNotFound(step.value)
            }
            _ = try await workspace.openApplication(at: appURL, configuration: .init())

        case .openURL:
            guard let url = URL(string: step.value), NSWorkspace.shared.open(url) else {
                throw HyperdeckExecutionError.invalidURL(step.value)
            }

        case .runShortcut:
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            components.queryItems = [URLQueryItem(name: "name", value: step.value)]
            if step.passesClipboard {
                components.queryItems?.append(URLQueryItem(name: "input", value: "clipboard"))
            }
            guard let url = components.url, NSWorkspace.shared.open(url) else {
                throw HyperdeckExecutionError.invalidURL("Shortcut \(step.value)")
            }

        case .delay:
            try await Task.sleep(for: .seconds(min(max(step.duration, 0), 300)))

        case .copyText:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(step.value, forType: .string)
            lastPasteboardChangeCount = pasteboard.changeCount

        case .showNotification:
            await onNotification?(step.value.isEmpty ? "Keyboard Studio" : step.value, step.detail)

        case .setRGB:
            await onRGB?(step.color)

        case .runExecutable:
            guard step.value.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: step.value) else {
                throw HyperdeckExecutionError.executableNotApproved(step.value)
            }
            let process = Process()
            process.executableURL = URL(filePath: step.value)
            process.arguments = step.arguments
            try process.run()

        case .openCodex:
            await onOpenCodex?()
        case .acknowledgeCodex:
            await onAcknowledgeCodex?()
        case .nextCodexReview:
            await onNextCodexReview?()
        case .showKeyboardStudio:
            await onShowStudio?()
        case .toggleFocus:
            toggleFocus()
        case .resetFocus:
            resetFocus()
        case .clipboardPrevious:
            selectPreviousClipboardItem()
        case .clipboardNext:
            selectNextClipboardItem()
        case .clipboardCopySelected:
            copySelectedClipboardItem()
        }
    }

    private func activate(_ application: NSRunningApplication) {
        activeApplicationName = application.localizedName ?? "Unknown app"
        activeBundleIdentifier = application.bundleIdentifier ?? ""
        resolveActiveProfile()
    }

    private func resolveActiveProfile() {
        let matched = configuration.profiles.first {
            !$0.bundleIdentifiers.isEmpty && $0.bundleIdentifiers.contains(activeBundleIdentifier)
        } ?? configuration.profiles.first(where: { $0.bundleIdentifiers.isEmpty })
            ?? configuration.profiles.first
        guard let matched else {
            activeProfileID = nil
            return
        }
        let changed = activeProfileID != matched.id
        activeProfileID = matched.id
        if changed {
            statusMessage = "\(matched.name) profile active for \(activeApplicationName)."
            record("Profile changed", detail: "\(matched.name) · \(activeApplicationName)")
            Task { [weak self] in await self?.onProfileChanged?(matched) }
        }
    }

    private func persistConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: Self.configurationKey)
    }

    private func synchronizeClipboardMonitoring() {
        clipboardTask?.cancel()
        clipboardTask = nil
        guard configuration.clipboardMonitoringEnabled else { return }
        captureClipboardIfChanged()
        clipboardTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { return }
                self.captureClipboardIfChanged()
            }
        }
    }

    private func captureClipboardIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let bounded = String(text.prefix(10_000))
        guard clipboardItems.first?.text != bounded else { return }
        clipboardItems.insert(HyperdeckClipboardItem(capturedAt: Date(), text: bounded), at: 0)
        if clipboardItems.count > 20 { clipboardItems.removeLast(clipboardItems.count - 20) }
        selectedClipboardIndex = 0
        statusMessage = "Clipboard Deck captured a new text item in memory."
    }

    private func updateFocusClock() async {
        guard focusState.isRunning, let focusEndsAt else { return }
        let remaining = max(0, focusEndsAt.timeIntervalSinceNow)
        let second = Int(remaining.rounded(.up))
        guard second != lastPublishedFocusSecond else { return }
        lastPublishedFocusSecond = second
        focusState.remaining = remaining
        if remaining <= 0 {
            focusState.isRunning = false
            focusState.completedSessions += 1
            self.focusEndsAt = nil
            statusMessage = "Focus session complete."
            record("Focus session complete", detail: "Completed sessions: \(focusState.completedSessions)")
            await onNotification?("Focus session complete", "Keyboard Studio finished your \(configuration.focusMinutes)-minute session.")
        }
        await onFocusChanged?(focusState)
    }

    private func record(_ title: String, detail: String, isError: Bool = false) {
        runtimeEvents.insert(HyperdeckRuntimeEvent(date: Date(), title: title, detail: detail, isError: isError), at: 0)
        if runtimeEvents.count > 100 { runtimeEvents.removeLast(runtimeEvents.count - 100) }
        if isError {
            Self.logger.error("\(title, privacy: .public): \(detail, privacy: .public)")
        } else {
            Self.logger.notice("\(title, privacy: .public): \(detail, privacy: .public)")
        }
    }
}
