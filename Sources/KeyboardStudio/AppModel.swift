import AppKit
import Combine
import Foundation
import KeyboardCore
import OSLog
import UniformTypeIdentifiers
import UserNotifications

struct CodexDeckPress: Identifiable {
    let id = UUID()
    let date: Date
    let key: String
    let action: String
    let detail: String
}

private struct CodexLampColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let off = CodexLampColor(red: 0, green: 0, blue: 0)
    static let workingBlue = CodexLampColor(red: 0, green: 104, blue: 255)
    static let attentionRed = CodexLampColor(red: 255, green: 24, blue: 48)
}

private struct CodexLampFrame: Equatable {
    let button1: CodexLampColor
    let button2: CodexLampColor

    static let off = CodexLampFrame(button1: .off, button2: .off)
}

enum ScriptPreset: String, CaseIterable, Identifiable {
    case tap
    case repeatWhileHeld
    case codexBlue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap: "Tap a key"
        case .repeatWhileHeld: "Repeat while held"
        case .codexBlue: "Set LED Codex blue"
        }
    }
}

private struct ExtendedDeviceConfiguration: Equatable {
    var lighting: [SayoLightingV2Configuration] = []
    var colorTables: [SayoIndexedRecord] = []
    var scriptSlots: [SayoNamedSlot] = []
    var scriptImage: [UInt8] = []
    var passwordSlots: [SayoNamedSlot] = []
    var stringSlots: [SayoIndexedRecord] = []
    var deviceName = ""
    var identity: SayoDeviceIdentityConfiguration?
    var message = "Connect the keyboard to load its full configuration."
}

@MainActor
final class AppModel: ObservableObject {
    let hyperdeck: HyperdeckController
    @Published var deviceSnapshot: SayoDeviceSnapshot?
    @Published var editableButtons: [SayoButtonConfiguration]
    @Published private var extendedDeviceConfiguration = ExtendedDeviceConfiguration()
    @Published var secretsAreLoaded = false
    @Published var includeSecretsInBackup = false
    @Published var selectedPasswordSlot = 0
    @Published var selectedStringSlot = 0
    @Published var selectedScriptSlot = 0
    @Published var selectedScriptPreset = ScriptPreset.tap
    @Published var selectedScriptKey: UInt8 = 0x04
    @Published var activities: [CodexActivity] = []
    @Published var selectedLayer = 0
    @Published var isLoadingDevice = false
    @Published var isSaving = false
    @Published var isLoadingActivities = false
    @Published var deviceMessage = "Looking for the second keyboard…"
    @Published var activityMessage = "Reading local Codex activity…"
    @Published var alertsAuthorized = false
    @Published var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var keyboardAccessStatus: SayoKeyboardAccessStatus = .unknown
    @Published var unreadActivityCount = 0
    @Published var activeCodexTaskCount = 0
    @Published var codexTaskWasInterrupted = false
    @Published var deckMessage = "Codex Deck is ready for new activity."
    @Published var selectedCodexReviewActivityID: String?
    @Published private(set) var deckPresses: [CodexDeckPress] = []

    var lightingConfigurations: [SayoLightingV2Configuration] {
        get { extendedDeviceConfiguration.lighting }
        set { setExtendedDeviceConfiguration(\.lighting, to: newValue) }
    }

    var colorTables: [SayoIndexedRecord] {
        get { extendedDeviceConfiguration.colorTables }
        set { setExtendedDeviceConfiguration(\.colorTables, to: newValue) }
    }

    var scriptSlots: [SayoNamedSlot] {
        get { extendedDeviceConfiguration.scriptSlots }
        set { setExtendedDeviceConfiguration(\.scriptSlots, to: newValue) }
    }

    var scriptImage: [UInt8] {
        get { extendedDeviceConfiguration.scriptImage }
        set { setExtendedDeviceConfiguration(\.scriptImage, to: newValue) }
    }

    var passwordSlots: [SayoNamedSlot] {
        get { extendedDeviceConfiguration.passwordSlots }
        set { setExtendedDeviceConfiguration(\.passwordSlots, to: newValue) }
    }

    var stringSlots: [SayoIndexedRecord] {
        get { extendedDeviceConfiguration.stringSlots }
        set { setExtendedDeviceConfiguration(\.stringSlots, to: newValue) }
    }

    var editableDeviceName: String {
        get { extendedDeviceConfiguration.deviceName }
        set { setExtendedDeviceConfiguration(\.deviceName, to: newValue) }
    }

    var deviceIdentityConfiguration: SayoDeviceIdentityConfiguration? {
        get { extendedDeviceConfiguration.identity }
        set { setExtendedDeviceConfiguration(\.identity, to: newValue) }
    }

    var configurationMessage: String {
        get { extendedDeviceConfiguration.message }
        set { setExtendedDeviceConfiguration(\.message, to: newValue) }
    }

    private func setExtendedDeviceConfiguration<Value: Equatable>(
        _ keyPath: WritableKeyPath<ExtendedDeviceConfiguration, Value>,
        to value: Value
    ) {
        guard extendedDeviceConfiguration[keyPath: keyPath] != value else { return }
        extendedDeviceConfiguration[keyPath: keyPath] = value
    }

    private let deviceService = SayoDeviceService()
    private let activityService = CodexActivityService()
    private var latestActivityTimestamp: Int64?
    private var hasLoadedActivities = false
    private var hasStarted = false
    private var activityPollingTask: Task<Void, Never>?
    private var runtimeStatus = CodexRuntimeStatus()
    private var originalLighting: [SayoLightingV2Configuration]?
    private var appliedLampFrame: CodexLampFrame?
    private var hyperdeckLampOverride: CodexLampFrame?
    private var profileFlashTask: Task<Void, Never>?
    private var studioWindowOpener: (() -> Void)?

    private static let acknowledgedTimestampKey = "codexDeckAcknowledgedAt"
    private static let runtimeAcknowledgedTimestampKey = "codexDeckRuntimeAcknowledgedAt"
    private static let statusLampEnabledKey = "codexStatusLampEnabled"
    private static let deckLogger = Logger(
        subsystem: "com.lucas.keyboardstudio",
        category: "CodexDeckInput"
    )

    init() {
        hyperdeck = HyperdeckController()
        editableButtons = Self.fallbackButtons
        if UserDefaults.standard.object(forKey: Self.statusLampEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.statusLampEnabledKey)
        }
        configureHyperdeck()
        HyperdeckIntentBridge.install(controller: hyperdeck)
        Task { [weak self] in
            await self?.start()
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        hyperdeck.start()

        async let deviceLoad: Void = refreshDevice()
        async let activityLoad: Void = refreshActivities(notifyNew: false)
        async let notificationLoad: Void = refreshNotificationAuthorizationStatus()
        _ = await (deviceLoad, activityLoad, notificationLoad)

        activityPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let storedInterval = UserDefaults.standard.object(forKey: "activityRefreshInterval") as? Double
                let interval = max(5, storedInterval ?? 15)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.refreshActivities(notifyNew: true, showsLoading: false)
            }
        }
    }

    func refreshDevice() async {
        guard !isLoadingDevice else { return }
        isLoadingDevice = true
        defer { isLoadingDevice = false }

        let accessStatus = await deviceService.accessStatus()
        if keyboardAccessStatus != accessStatus {
            keyboardAccessStatus = accessStatus
        }

        do {
            let snapshot = try await deviceService.readSnapshot()
            deviceSnapshot = snapshot
            editableButtons = snapshot.buttons
            selectedLayer = min(selectedLayer, max(0, availableLayerCount - 1))
            await loadExtendedConfiguration(for: snapshot)
            let version = snapshot.firmwareVersion.map { String(format: "0x%04X", $0) } ?? "unknown"
            deviceMessage = "Connected · firmware \(version) · \(snapshot.buttons.count) buttons"
            await synchronizeCodexStatusLamp()
        } catch {
            deviceSnapshot = nil
            deviceMessage = error.localizedDescription
        }
    }

    /// Activation only needs to detect a newly connected or disconnected pad.
    /// A full configuration reload is intentionally reserved for launch and the
    /// explicit Refresh button because it performs dozens of HID transactions.
    func refreshDevicePresence() async {
        let accessStatus = await deviceService.accessStatus()
        if keyboardAccessStatus != accessStatus {
            keyboardAccessStatus = accessStatus
        }
        guard accessStatus == .granted else { return }

        let isPresent = await deviceService.isPresent()
        if isPresent {
            if deviceSnapshot == nil {
                await refreshDevice()
            }
        } else if deviceSnapshot != nil {
            deviceSnapshot = nil
            deviceMessage = "The second keyboard was disconnected."
        }
    }

    func requestKeyboardAccess() async {
        let granted = await deviceService.requestAccess()
        keyboardAccessStatus = await deviceService.accessStatus()
        if granted || keyboardAccessStatus == .granted {
            deviceMessage = "Keyboard access granted. Reloading the device…"
            await refreshDevice()
        } else {
            openInputMonitoringSettings()
            deviceMessage = "Input Monitoring is open in System Settings. Enable Keyboard Studio there, then quit and reopen the app."
        }
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func restartApplication() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            deviceMessage = "Restart is available from the packaged Keyboard Studio app."
            return
        }

        let relauncher = Process()
        relauncher.executableURL = URL(filePath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "sleep 0.75; exec /usr/bin/open -n \"$KEYBOARD_STUDIO_APP\"",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["KEYBOARD_STUDIO_APP"] = appURL.path
        relauncher.environment = environment

        do {
            try relauncher.run()
            NSApplication.shared.terminate(nil)
        } catch {
            deviceMessage = "Could not restart Keyboard Studio: \(error.localizedDescription)"
        }
    }

    func saveDevice() async {
        guard deviceSnapshot != nil else {
            deviceMessage = "Connect the SayoDevice before saving."
            return
        }

        isSaving = true
        deviceMessage = "Writing and verifying both buttons…"
        defer { isSaving = false }
        do {
            let verified = try await deviceService.writeAndSave(buttons: editableButtons)
            editableButtons = verified
            deviceMessage = "Saved to keyboard flash and verified."
            await refreshDevice()
        } catch {
            deviceMessage = "Save failed without completing: \(error.localizedDescription)"
        }
    }

    func saveLighting() async {
        guard supportsRGBLighting else {
            configurationMessage = "This firmware does not advertise Lighting v2."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await restoreOriginalLightingIfNeeded()
            var verified: [SayoLightingV2Configuration] = []
            for configuration in lightingConfigurations {
                verified.append(try await deviceService.writeLightingV2(configuration))
            }
            try await deviceService.saveToFlash()
            lightingConfigurations = verified
            originalLighting = verified
            appliedLampFrame = nil
            configurationMessage = "Lighting effects saved to flash and verified."
            await synchronizeCodexStatusLamp(force: true)
        } catch {
            configurationMessage = "Lighting was not saved: \(error.localizedDescription)"
        }
    }

    func saveColorTables() async {
        isSaving = true
        defer { isSaving = false }
        do {
            var verified: [SayoIndexedRecord] = []
            for record in colorTables {
                verified.append(try await deviceService.writeIndexedRecord(command: 0x11, record: record))
            }
            try await deviceService.saveToFlash()
            colorTables = verified
            configurationMessage = "All six color tables were saved and verified."
        } catch {
            configurationMessage = "Color tables were not saved: \(error.localizedDescription)"
        }
    }

    func saveDeviceName() async {
        isSaving = true
        defer { isSaving = false }
        do {
            editableDeviceName = try await deviceService.writeDeviceName(editableDeviceName)
            try await deviceService.saveToFlash()
            configurationMessage = "Device name saved. Reconnect the keyboard if macOS still shows the old name."
        } catch {
            configurationMessage = "Device name was not saved: \(error.localizedDescription)"
        }
    }

    func loadSecrets() async {
        guard deviceSnapshot?.supportedCommands.contains(0x0B) == true else {
            configurationMessage = "This firmware does not advertise password slots."
            return
        }
        isLoadingDevice = true
        defer { isLoadingDevice = false }
        do {
            passwordSlots = try await deviceService.readPasswordSlots()
            secretsAreLoaded = true
            configurationMessage = "Loaded \(passwordSlots.count) password slots. Values stay in this app unless you explicitly include them in a backup."
        } catch {
            configurationMessage = "Password slots could not be loaded: \(error.localizedDescription)"
        }
    }

    func savePasswords() async {
        guard secretsAreLoaded else {
            configurationMessage = "Load the password slots before editing them."
            return
        }
        guard passwordSlots.indices.contains(selectedPasswordSlot) else {
            configurationMessage = "Select a password slot before saving."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let verified = try await deviceService.writePasswordSlot(passwordSlots[selectedPasswordSlot])
            try await deviceService.saveToFlash()
            passwordSlots[selectedPasswordSlot] = verified
            configurationMessage = "Password slot \(selectedPasswordSlot + 1) saved and read back."
        } catch {
            configurationMessage = "Passwords were not saved: \(error.localizedDescription)"
        }
    }

    func textValue(for recordIndex: Int) -> String {
        guard stringSlots.indices.contains(recordIndex) else { return "" }
        let values = stringSlots[recordIndex].values
        var bytes: [UInt8] = []
        var index = 0
        while index + 1 < min(56, values.count) {
            if values[index] == 0, values[index + 1] != 0 {
                bytes.append(values[index + 1])
            } else if values[index] != 0 || values[index + 1] != 0 {
                bytes.append(values[index])
                bytes.append(values[index + 1])
            } else {
                break
            }
            index += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func setTextValue(_ text: String, for recordIndex: Int) {
        guard stringSlots.indices.contains(recordIndex) else { return }
        let bytes = Array(text.utf8.prefix(28))
        var encoded: [UInt8] = []
        for byte in bytes { encoded += [0, byte] }
        encoded += [UInt8](repeating: 0, count: max(0, 56 - encoded.count))
        var record = stringSlots[recordIndex]
        let tail = record.values.count > 56 ? Array(record.values.dropFirst(56)) : []
        record.values = Array(encoded.prefix(56)) + tail
        stringSlots[recordIndex] = record
    }

    func saveStrings() async {
        guard stringSlots.indices.contains(selectedStringSlot) else {
            configurationMessage = "Select a text slot before saving."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let verified = try await deviceService.writeIndexedRecord(
                command: 0x0C,
                record: stringSlots[selectedStringSlot]
            )
            try await deviceService.saveToFlash()
            stringSlots[selectedStringSlot] = verified
            configurationMessage = "Text slot \(selectedStringSlot + 1) saved and verified."
        } catch {
            configurationMessage = "Text slots were not saved: \(error.localizedDescription)"
        }
    }

    func saveScripts() async {
        isSaving = true
        defer { isSaving = false }
        do {
            var verifiedNames: [SayoNamedSlot] = []
            for slot in scriptSlots {
                verifiedNames.append(try await deviceService.writeNamedSlot(command: 0xF1, slot: slot))
            }
            _ = try await deviceService.writeRawScriptImage(scriptImage)
            try await deviceService.saveToFlash()
            scriptSlots = verifiedNames
            configurationMessage = "Script names and bytecode saved and verified."
        } catch {
            configurationMessage = "Scripts were not saved: \(error.localizedDescription)"
        }
    }

    func applyScriptTemplate(slot: Int, template: ScriptPreset, key: UInt8 = 0x04) {
        guard scriptSlots.indices.contains(slot) else { return }
        scriptImage = switch template {
        case .tap: SayoScriptTemplate.tapKey(key)
        case .repeatWhileHeld: SayoScriptTemplate.repeatWhileHeld(key)
        case .codexBlue: SayoScriptTemplate.setSelectedLED(red: 0, green: 104, blue: 255)
        }
        if scriptSlots[slot].name.isEmpty {
            scriptSlots[slot].name = template.title
        }
        configurationMessage = "\(template.title) staged for the script image. Save Scripts to write it."
    }

    func exportBackup() async {
        guard let snapshot = deviceSnapshot else {
            configurationMessage = "Connect the keyboard before creating a backup."
            return
        }
        let backup = SayoDeviceBackup(
            product: snapshot.product,
            serialNumber: snapshot.serialNumber,
            modelCode: snapshot.modelCode,
            firmwareVersion: snapshot.firmwareVersion,
            buttons: editableButtons,
            lighting: lightingConfigurations,
            colorTables: colorTables,
            scriptNames: scriptSlots,
            scriptImage: scriptImage,
            deviceName: editableDeviceName,
            passwords: includeSecretsInBackup && secretsAreLoaded ? passwordSlots : nil,
            strings: stringSlots
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(snapshot.product.replacingOccurrences(of: " ", with: "-"))-backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(backup).write(to: url, options: .atomic)
            configurationMessage = includeSecretsInBackup && secretsAreLoaded
                ? "Backup exported with password slots. Keep the file private."
                : "Backup exported without password values."
        } catch {
            configurationMessage = "Backup export failed: \(error.localizedDescription)"
        }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(SayoDeviceBackup.self, from: Data(contentsOf: url))
            guard backup.format == "Keyboard Studio SayoDevice Backup 1.0" else {
                throw SayoProtocolError.invalidPacket("unrecognized backup format")
            }
            if let currentModel = deviceSnapshot?.modelCode,
               let backupModel = backup.modelCode,
               currentModel != backupModel
            {
                throw SayoProtocolError.invalidPacket("backup model does not match the connected keyboard")
            }
            editableButtons = backup.buttons
            var importedConfiguration = extendedDeviceConfiguration
            importedConfiguration.lighting = backup.lighting
            importedConfiguration.colorTables = backup.colorTables
            importedConfiguration.scriptSlots = backup.scriptNames
            importedConfiguration.scriptImage = backup.scriptImage
            importedConfiguration.deviceName = backup.deviceName
            importedConfiguration.stringSlots = backup.strings
            if let passwords = backup.passwords {
                importedConfiguration.passwordSlots = passwords
                secretsAreLoaded = true
            }
            importedConfiguration.message = "Backup imported and staged. Review each page, then use its Save button to apply."
            if extendedDeviceConfiguration != importedConfiguration {
                extendedDeviceConfiguration = importedConfiguration
            }
        } catch {
            configurationMessage = "Backup import failed: \(error.localizedDescription)"
        }
    }

    func installCodexDeck() async {
        guard deviceSnapshot != nil else {
            deckMessage = "Enable Input Monitoring and reload the SayoDevice before installing Codex Deck."
            return
        }

        isSaving = true
        deckMessage = "Installing F13/F16 on Layer 1 and verifying the keyboard…"
        defer { isSaving = false }

        do {
            let configured = try CodexDeckProfile.applying(to: editableButtons)
            let verified = try await deviceService.writeAndSave(buttons: configured)
            editableButtons = verified
            deckMessage = "Codex Deck installed. Button 1 opens Codex; Button 2 clears alerts."
            await refreshDevice()
        } catch {
            deckMessage = "Codex Deck was not installed: \(error.localizedDescription)"
        }
    }

    func refreshActivities(notifyNew: Bool = false, showsLoading: Bool = true) async {
        if showsLoading { isLoadingActivities = true }
        defer {
            if showsLoading { isLoadingActivities = false }
        }

        do {
            let refreshed = try await activityService.recent()
            let refreshedRuntimeStatus = await activityService.runtimeStatus()
            let previousTimestamp = latestActivityTimestamp
            if activities != refreshed { activities = refreshed }
            if runtimeStatus != refreshedRuntimeStatus { runtimeStatus = refreshedRuntimeStatus }
            if activeCodexTaskCount != refreshedRuntimeStatus.activeTaskCount {
                activeCodexTaskCount = refreshedRuntimeStatus.activeTaskCount
            }
            latestActivityTimestamp = refreshed.map(\.updatedAt).max()
            if !hasLoadedActivities,
               UserDefaults.standard.object(forKey: Self.acknowledgedTimestampKey) == nil,
               let latestActivityTimestamp
            {
                setAcknowledgedTimestamp(latestActivityTimestamp)
            }
            if !hasLoadedActivities,
               UserDefaults.standard.object(forKey: Self.runtimeAcknowledgedTimestampKey) == nil,
               let latestRuntimeTimestamp = refreshedRuntimeStatus.lastAttentionAt
            {
                setRuntimeAcknowledgedTimestamp(latestRuntimeTimestamp)
            }
            let refreshedUnreadCount = refreshed.filter { $0.updatedAt > acknowledgedTimestamp }.count
            if unreadActivityCount != refreshedUnreadCount { unreadActivityCount = refreshedUnreadCount }
            let wasInterrupted = (refreshedRuntimeStatus.lastInterruptedAt ?? 0) > runtimeAcknowledgedTimestamp
            if codexTaskWasInterrupted != wasInterrupted { codexTaskWasInterrupted = wasInterrupted }
            let refreshedDeckMessage: String
            if activeCodexTaskCount > 0, hasCodexAttentionWaiting {
                refreshedDeckMessage = "Codex is working on \(activeCodexTaskCount) \(activeCodexTaskCount == 1 ? "task" : "tasks") · another result is waiting."
            } else if activeCodexTaskCount > 0 {
                refreshedDeckMessage = "Codex is working on \(activeCodexTaskCount) \(activeCodexTaskCount == 1 ? "task" : "tasks")."
            } else if codexTaskWasInterrupted {
                refreshedDeckMessage = "A Codex task stopped and needs attention."
            } else if hasCodexAttentionWaiting {
                refreshedDeckMessage = "A Codex result is ready."
            } else {
                refreshedDeckMessage = supportsRGBLighting
                    ? "All caught up. The status lamp is watching Codex."
                    : "All caught up."
            }
            if deckMessage != refreshedDeckMessage { deckMessage = refreshedDeckMessage }
            let refreshedActivityMessage = refreshed.isEmpty
                ? "No local Codex summaries yet."
                : "Watching \(refreshed.count) recent task summaries"
            if activityMessage != refreshedActivityMessage { activityMessage = refreshedActivityMessage }

            if notifyNew, hasLoadedActivities, let previousTimestamp {
                let newActivities = refreshed
                    .filter { $0.updatedAt > previousTimestamp }
                    .sorted { $0.updatedAt < $1.updatedAt }
                for activity in newActivities {
                    await deliverNotification(for: activity)
                }
            }
            hasLoadedActivities = true
            await synchronizeCodexStatusLamp()
        } catch {
            activityMessage = error.localizedDescription
        }
    }

    func requestNotificationAccess() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshNotificationAuthorizationStatus()
            activityMessage = alertsAuthorized
                ? "macOS alerts enabled; the activity list remains the source of truth."
                : "Notification access is off. You can still use the in-app activity list."
        } catch {
            activityMessage = "Could not enable alerts: \(error.localizedDescription)"
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openCodex() {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            workspace.openApplication(at: url, configuration: .init())
            deckMessage = "Codex brought forward. Press Button 2 when you are caught up."
            return
        }
        let fallback = URL(filePath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: fallback.path) {
            workspace.openApplication(at: fallback, configuration: .init())
            deckMessage = "Codex brought forward. Press Button 2 when you are caught up."
        } else {
            activityMessage = "Codex.app was not found in Applications."
            deckMessage = activityMessage
        }
    }

    func acknowledgeCodexDeck() async {
        let timestamp = activities.map(\.updatedAt).max()
            ?? Int64(Date().timeIntervalSince1970 * 1000)
        setAcknowledgedTimestamp(timestamp)
        let runtimeTimestamp = runtimeStatus.lastAttentionAt
            ?? Int64(Date().timeIntervalSince1970)
        setRuntimeAcknowledgedTimestamp(runtimeTimestamp)
        unreadActivityCount = 0
        codexTaskWasInterrupted = false
        deckMessage = activeCodexTaskCount > 0
            ? "Caught up. Codex is still working, so Button 1 stays blue."
            : "All caught up. The keyboard's normal lighting is restored."
        await synchronizeCodexStatusLamp(force: true)
    }

    func showKeyboardStudio() {
        studioWindowOpener?()
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await Task.yield()
            NSApplication.shared.windows.first(where: {
                $0.title.contains("Keyboard Studio") || $0.title == "Hyperdeck"
            })?.makeKeyAndOrderFront(nil)
        }
    }

    func installStudioWindowOpener(_ opener: @escaping () -> Void) {
        studioWindowOpener = opener
    }

    func selectNextCodexReview() {
        let unread = activities.filter { $0.updatedAt > acknowledgedTimestamp }
        let candidates = unread.isEmpty ? activities : unread
        guard !candidates.isEmpty else {
            deckMessage = "No Codex activity is available to review."
            return
        }
        if let selectedCodexReviewActivityID,
           let current = candidates.firstIndex(where: { $0.id == selectedCodexReviewActivityID })
        {
            self.selectedCodexReviewActivityID = candidates[(current + 1) % candidates.count].id
        } else {
            selectedCodexReviewActivityID = candidates[0].id
        }
        UserDefaults.standard.set(StudioSection.activity.rawValue, forKey: "selectedStudioSection")
        showKeyboardStudio()
        deckMessage = "Selected the next Codex activity for review."
    }

    func previewCodexDeckLight() async {
        guard deviceSnapshot != nil else {
            deckMessage = "Connect the SayoDevice before testing its RGB alert."
            return
        }
        guard supportsRGBLighting else {
            deckMessage = "This firmware does not advertise Lighting v2 command 16, so RGB control is unavailable."
            return
        }
        do {
            try await preserveOriginalLightingIfNeeded()
            let preview = CodexLampFrame(button1: .workingBlue, button2: .attentionRed)
            try await applyLampFrame(preview)
            appliedLampFrame = preview
            deckMessage = "Status lamp preview: Button 1 is working blue; Button 2 is attention red."
        } catch {
            deckMessage = "RGB preview failed: \(error.localizedDescription)"
        }
    }

    func codexStatusLampSettingChanged() async {
        await synchronizeCodexStatusLamp(force: true)
    }

    var isCodexDeckInstalled: Bool {
        CodexDeckProfile.isInstalled(in: editableButtons)
    }

    var supportsRGBLighting: Bool {
        deviceSnapshot?.supportedCommands.contains(0x10) == true
    }

    var hasCodexAttentionWaiting: Bool {
        unreadActivityCount > 0
            || (runtimeStatus.lastAttentionAt ?? 0) > runtimeAcknowledgedTimestamp
    }

    var availableLayerCount: Int {
        max(1, editableButtons.map(\.layers.count).max() ?? 1)
    }

    func layer(for buttonIndex: Int) -> SayoKeyLayer {
        guard editableButtons.indices.contains(buttonIndex),
              editableButtons[buttonIndex].layers.indices.contains(selectedLayer)
        else {
            return SayoKeyLayer(id: selectedLayer)
        }
        return editableButtons[buttonIndex].layers[selectedLayer]
    }

    func setLayer(_ layer: SayoKeyLayer, for buttonIndex: Int) {
        guard editableButtons.indices.contains(buttonIndex),
              editableButtons[buttonIndex].layers.indices.contains(selectedLayer)
        else { return }
        editableButtons[buttonIndex].layers[selectedLayer] = layer
    }

    func applyCopyPasteProfile() {
        setKeyboardAction(buttonIndex: 0, modifier: HIDModifier.command.rawValue, primaryKey: 0x06)
        setKeyboardAction(buttonIndex: 1, modifier: HIDModifier.command.rawValue, primaryKey: 0x19)
        deviceMessage = "Copy/Paste staged on Layer \(selectedLayer + 1). Save to apply."
    }

    func applyCodexTriggerProfile() {
        setKeyboardAction(buttonIndex: 0, modifier: 0, primaryKey: 0x68)
        setKeyboardAction(buttonIndex: 1, modifier: 0, primaryKey: 0x6B)
        deviceMessage = "F13/F16 triggers staged on Layer \(selectedLayer + 1). Save, then bind them in macOS Shortcuts."
    }

    private func setKeyboardAction(buttonIndex: Int, modifier: UInt8, primaryKey: UInt8) {
        var value = layer(for: buttonIndex)
        value.mode = 0
        value.modifier = modifier
        value.keyCodes = [primaryKey, 0, 0]
        setLayer(value, for: buttonIndex)
    }

    private func loadExtendedConfiguration(for snapshot: SayoDeviceSnapshot) async {
        var loadedConfiguration = extendedDeviceConfiguration
        do {
            if snapshot.supportedCommands.contains(0x10) {
                loadedConfiguration.lighting = try await [
                    deviceService.readLightingV2(number: 0),
                    deviceService.readLightingV2(number: 1),
                ]
            }
            if snapshot.supportedCommands.contains(0x11) {
                loadedConfiguration.colorTables = try await deviceService.readIndexedRecords(command: 0x11, limit: 6)
            }
            if snapshot.supportedCommands.contains(0x08) {
                loadedConfiguration.deviceName = try await deviceService.readDeviceName()
            }
            if snapshot.supportedCommands.contains(0xFE) {
                loadedConfiguration.identity = try await deviceService.readDeviceIdentityConfiguration()
            }
            if snapshot.supportedCommands.contains(0xF1) {
                loadedConfiguration.scriptSlots = try await deviceService.readNamedSlots(command: 0xF1, limit: 2)
            }
            if snapshot.supportedCommands.contains(0xF0) {
                loadedConfiguration.scriptImage = try await deviceService.readRawScriptImage()
            }
            if snapshot.supportedCommands.contains(0x0C) {
                loadedConfiguration.stringSlots = try await deviceService.readIndexedRecords(command: 0x0C, limit: 16)
            }
            loadedConfiguration.message = "Loaded keys, lighting, palettes, scripts, strings, and device settings from the keyboard."
        } catch {
            loadedConfiguration.message = "The basic key map loaded, but an extended feature failed: \(error.localizedDescription)"
        }
        if extendedDeviceConfiguration != loadedConfiguration {
            extendedDeviceConfiguration = loadedConfiguration
        }
    }

    private func deliverNotification(for activity: CodexActivity) async {
        guard alertsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = activity.compactSummary ?? "Codex task updated"
        content.body = activity.summary
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "codex-\(activity.threadID)-\(activity.updatedAt)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func refreshNotificationAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        alertsAuthorized = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    private var acknowledgedTimestamp: Int64 {
        (UserDefaults.standard.object(forKey: Self.acknowledgedTimestampKey) as? NSNumber)?.int64Value ?? 0
    }

    private func setAcknowledgedTimestamp(_ timestamp: Int64) {
        UserDefaults.standard.set(NSNumber(value: timestamp), forKey: Self.acknowledgedTimestampKey)
    }

    private var runtimeAcknowledgedTimestamp: Int64 {
        (UserDefaults.standard.object(forKey: Self.runtimeAcknowledgedTimestampKey) as? NSNumber)?.int64Value ?? 0
    }

    private func setRuntimeAcknowledgedTimestamp(_ timestamp: Int64) {
        UserDefaults.standard.set(NSNumber(value: timestamp), forKey: Self.runtimeAcknowledgedTimestampKey)
    }

    private func synchronizeCodexStatusLamp(force: Bool = false) async {
        guard deviceSnapshot != nil, supportsRGBLighting else { return }

        let enabled = UserDefaults.standard.bool(forKey: Self.statusLampEnabledKey)
        let desiredFrame = hyperdeckLampOverride ?? (enabled
            ? CodexLampFrame(
                button1: activeCodexTaskCount > 0 ? .workingBlue : .off,
                button2: hasCodexAttentionWaiting ? .attentionRed : .off
            )
            : .off)

        do {
            if desiredFrame == .off {
                try await restoreOriginalLightingIfNeeded()
                return
            }
            guard force || appliedLampFrame != desiredFrame else { return }
            try await preserveOriginalLightingIfNeeded()
            try await applyLampFrame(desiredFrame)
            appliedLampFrame = desiredFrame
        } catch {
            deckMessage = "Codex status updated, but the lamp could not sync: \(error.localizedDescription)"
        }
    }

    private func preserveOriginalLightingIfNeeded() async throws {
        guard originalLighting == nil else { return }
        originalLighting = [
            try await deviceService.readLightingV2(number: 0),
            try await deviceService.readLightingV2(number: 1),
        ]
    }

    private func restoreOriginalLightingIfNeeded() async throws {
        guard let originalLighting else {
            appliedLampFrame = nil
            return
        }
        for configuration in originalLighting {
            try await deviceService.writeLightingV2(configuration)
        }
        self.originalLighting = nil
        appliedLampFrame = nil
    }

    private func applyLampFrame(_ frame: CodexLampFrame) async throws {
        try await deviceService.setStaticLighting(
            number: 0,
            red: frame.button1.red,
            green: frame.button1.green,
            blue: frame.button1.blue
        )
        try await deviceService.setStaticLighting(
            number: 1,
            red: frame.button2.red,
            green: frame.button2.green,
            blue: frame.button2.blue
        )
    }

    private func recordPhysicalPress(_ event: HyperdeckPhysicalEvent) {
        guard event.phase == .down else { return }
        let press = CodexDeckPress(
            date: Date(),
            key: event.key == .left ? "F13" : "F16",
            action: "Physical press",
            detail: "Hyperdeck received the key; gesture recognition is active."
        )
        deckPresses.insert(press, at: 0)
        if deckPresses.count > 20 {
            deckPresses.removeLast(deckPresses.count - 20)
        }
        Self.deckLogger.notice(
            "Key press key=\(press.key, privacy: .public) action=\(press.action, privacy: .public)"
        )
    }

    private func configureHyperdeck() {
        hyperdeck.onOpenCodex = { [weak self] in self?.openCodex() }
        hyperdeck.onAcknowledgeCodex = { [weak self] in await self?.acknowledgeCodexDeck() }
        hyperdeck.onNextCodexReview = { [weak self] in self?.selectNextCodexReview() }
        hyperdeck.onShowStudio = { [weak self] in self?.showKeyboardStudio() }
        hyperdeck.onNotification = { [weak self] title, body in
            await self?.deliverNotification(title: title, body: body)
        }
        hyperdeck.onRGB = { [weak self] color in await self?.flashHyperdeckColor(color) }
        hyperdeck.onProfileChanged = { [weak self] profile in await self?.flashHyperdeckColor(profile.color) }
        hyperdeck.onFocusChanged = { [weak self] state in await self?.updateFocusLamp(state) }
        hyperdeck.onPhysicalEvent = { [weak self] event in self?.recordPhysicalPress(event) }
    }

    private func deliverNotification(title: String, body: String) async {
        guard alertsAuthorized else {
            activityMessage = "Notification action skipped because macOS alerts are not enabled."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "hyperdeck-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    private func flashHyperdeckColor(_ color: HyperdeckRGBColor) async {
        guard supportsRGBLighting, !hyperdeck.focusState.isRunning else { return }
        profileFlashTask?.cancel()
        let previous = hyperdeckLampOverride
        let lampColor = CodexLampColor(red: color.red, green: color.green, blue: color.blue)
        let frame = CodexLampFrame(button1: lampColor, button2: lampColor)
        hyperdeckLampOverride = frame
        await synchronizeCodexStatusLamp(force: true)
        profileFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.hyperdeckLampOverride = previous
            await self.synchronizeCodexStatusLamp(force: true)
        }
    }

    private func updateFocusLamp(_ state: HyperdeckFocusState) async {
        profileFlashTask?.cancel()
        if state.isRunning {
            let color: CodexLampColor = state.remaining <= 60
                ? CodexLampColor(red: 255, green: 150, blue: 32)
                : CodexLampColor(red: 44, green: 210, blue: 120)
            hyperdeckLampOverride = CodexLampFrame(button1: color, button2: .off)
            await synchronizeCodexStatusLamp()
        } else if state.remaining <= 0 {
            hyperdeckLampOverride = CodexLampFrame(button1: .off, button2: .attentionRed)
            await synchronizeCodexStatusLamp(force: true)
            profileFlashTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.hyperdeckLampOverride = nil
                await self.synchronizeCodexStatusLamp(force: true)
            }
        } else {
            hyperdeckLampOverride = nil
            await synchronizeCodexStatusLamp(force: true)
        }
    }

    private static let fallbackButtons: [SayoButtonConfiguration] = [
        SayoButtonConfiguration(
            number: 0,
            header: [0, 0] + [UInt8](repeating: 0, count: 14),
            layers: (0 ..< 5).map { SayoKeyLayer(id: $0, keyCodes: [0x06, 0, 0]) },
            usesModernKeyMap: true
        ),
        SayoButtonConfiguration(
            number: 1,
            header: [0, 1] + [UInt8](repeating: 0, count: 14),
            layers: (0 ..< 5).map { SayoKeyLayer(id: $0, keyCodes: [0x19, 0, 0]) },
            usesModernKeyMap: true
        ),
    ]
}
