import KeyboardCore
import SwiftUI
import UserNotifications

enum StudioSection: String, CaseIterable, Identifiable {
    case keyboard = "Keyboard"
    case lighting = "Lighting"
    case macros = "Text & Passwords"
    case scripts = "Scripts"
    case device = "Device"
    case backups = "Backup & Restore"
    case hyperdeck = "Hyperdeck"
    case codexDeck = "Codex Deck"
    case activity = "Codex Activity"
    case protocolInfo = "Protocol"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .keyboard: "keyboard"
        case .lighting: "lightbulb.led.fill"
        case .macros: "text.cursor"
        case .scripts: "chevron.left.forwardslash.chevron.right"
        case .device: "gearshape.2.fill"
        case .backups: "externaldrive.fill.badge.timemachine"
        case .hyperdeck: "rectangle.2.swap"
        case .codexDeck: "sparkles.rectangle.stack.fill"
        case .activity: "bell.badge"
        case .protocolInfo: "cable.connector"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("selectedStudioSection") private var selectedSectionRaw = StudioSection.keyboard.rawValue

    private var selectedSection: StudioSection {
        StudioSection(rawValue: selectedSectionRaw) ?? .keyboard
    }

    private var selectionBinding: Binding<StudioSection?> {
        Binding(
            get: { selectedSection },
            set: { selectedSectionRaw = ($0 ?? .keyboard).rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(StudioSection.allCases, selection: selectionBinding) { section in
                HStack {
                    Label(section.rawValue, systemImage: section.icon)
                    Spacer()
                    if section == .codexDeck, model.unreadActivityCount > 0 {
                        Text(model.unreadActivityCount, format: .number)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.purple, in: Capsule())
                    }
                }
                    .tag(section)
            }
            .navigationTitle("Keyboard Studio")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            switch selectedSection {
            case .keyboard:
                KeyboardEditorView(model: model)
            case .lighting:
                LightingStudioView(model: model)
            case .macros:
                MacrosStudioView(model: model)
            case .scripts:
                ScriptsStudioView(model: model)
            case .device:
                DeviceSettingsStudioView(model: model)
            case .backups:
                BackupStudioView(model: model)
            case .hyperdeck:
                HyperdeckStudioView(controller: model.hyperdeck)
            case .codexDeck:
                CodexDeckView(model: model)
            case .activity:
                CodexActivityView(model: model)
            case .protocolInfo:
                ProtocolView(snapshot: model.deviceSnapshot)
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshDevice() }
        }
        .onOpenURL { model.hyperdeck.handleDeepLink($0) }
    }
}

private struct CodexDeckView: View {
    @ObservedObject var model: AppModel
    @AppStorage("codexStatusLampEnabled") private var codexStatusLampEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                deckHero

                HStack(alignment: .top, spacing: 18) {
                    DeckKeyCard(
                        button: "BUTTON 1",
                        key: "F13",
                        title: "Open Codex",
                        detail: "Brings Codex forward from any app.",
                        icon: "arrow.up.forward.app.fill",
                        colors: [.purple, .blue]
                    )
                    DeckKeyCard(
                        button: "BUTTON 2",
                        key: "F16",
                        title: "Clear alerts",
                        detail: "Marks updates caught up and turns off RGB when supported.",
                        icon: "checkmark.circle.fill",
                        colors: [.blue, .cyan]
                    )
                }

                GroupBox("Install on the keyboard") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.isCodexDeckInstalled ? "Codex Deck is installed on Layer 1" : "Map Layer 1 to F13 and F16")
                                    .font(.headline)
                                Text("All other layers and every opaque device setting stay untouched.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.keyboardAccessStatus != .granted {
                                Button("Open Input Monitoring") {
                                    Task { await model.requestKeyboardAccess() }
                                }
                                Button("Restart Keyboard Studio") {
                                    model.restartApplication()
                                }
                            }
                            Button(model.isCodexDeckInstalled ? "Reinstall" : "Install Codex Deck") {
                                Task { await model.installCodexDeck() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.deviceSnapshot == nil || model.isSaving)
                        }

                        Divider()

                        HStack(spacing: 18) {
                            Toggle("Use the pad as a Codex status lamp", isOn: $codexStatusLampEnabled)
                                .toggleStyle(.switch)
                                .disabled(!model.supportsRGBLighting)
                                .help(model.supportsRGBLighting
                                    ? "Blue means Codex is working; red means a result needs attention."
                                    : "This firmware does not advertise Lighting v2 command 16.")
                            Spacer()
                            Button("Test RGB") {
                                Task { await model.previewCodexDeckLight() }
                            }
                            .disabled(model.deviceSnapshot == nil || !model.supportsRGBLighting)
                            Button("Open Codex") { model.openCodex() }
                            Button("Clear alert") {
                                Task { await model.acknowledgeCodexDeck() }
                            }
                        }

                        HStack(spacing: 22) {
                            StatusLampLegend(
                                color: Color(red: 0, green: 104 / 255, blue: 1),
                                title: "Button 1 · Working",
                                detail: model.activeCodexTaskCount == 0
                                    ? "No Codex task is running"
                                    : "\(model.activeCodexTaskCount) \(model.activeCodexTaskCount == 1 ? "task is" : "tasks are") running"
                            )
                            StatusLampLegend(
                                color: Color(red: 1, green: 24 / 255, blue: 48 / 255),
                                title: "Button 2 · Attention",
                                detail: model.hasCodexAttentionWaiting
                                    ? (model.codexTaskWasInterrupted ? "A task stopped" : "A result is ready")
                                    : "Nothing is waiting"
                            )
                            Spacer()
                        }
                    }
                    .padding(8)
                }

                GroupBox("Recent key presses") {
                    if model.deckPresses.isEmpty {
                        Text("Press either keyboard button to verify that Keyboard Studio received it.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.deckPresses.prefix(8)) { press in
                                HStack(spacing: 12) {
                                    Text(press.key)
                                        .font(.caption.monospaced().weight(.bold))
                                        .frame(width: 38)
                                        .padding(.vertical, 5)
                                        .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(press.action).fontWeight(.semibold)
                                        Text(press.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(press.date, format: .dateTime.hour().minute().second())
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                                if press.id != model.deckPresses.prefix(8).last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "menubar.rectangle")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Always within reach")
                            .font(.headline)
                        Text("Codex Deck also lives in the menu bar, so the remote and unread count keep working after the main window closes. F13 and F16 are registered as dedicated system hot keys: Keyboard Studio does not inspect other keystrokes or request Accessibility access. Input Monitoring is used only to connect to and configure the SayoDevice.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Codex Deck")
        .toolbar {
            Button {
                Task {
                    await model.refreshDevice()
                    await model.refreshActivities()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingDevice || model.isLoadingActivities || model.isSaving)
        }
        .onChange(of: codexStatusLampEnabled) { _, _ in
            Task { await model.codexStatusLampSettingChanged() }
        }
    }

    private var deckHero: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(
                        LinearGradient(
                            colors: [.purple, .indigo, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: model.unreadActivityCount > 0 ? "bell.badge.fill" : "sparkles")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 96, height: 96)
            .shadow(color: .purple.opacity(0.22), radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 7) {
                Text("Codex Deck")
                    .font(.largeTitle.bold())
                Text(model.deckMessage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(model.unreadActivityCount, format: .number)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(model.unreadActivityCount > 0 ? .purple : .green)
                    .contentTransition(.numericText())
                Text(model.unreadActivityCount == 1 ? "UNREAD UPDATE" : "UNREAD UPDATES")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct StatusLampLegend: View {
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .shadow(color: color.opacity(0.75), radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeckKeyCard: View {
    let button: String
    let key: String
    let title: String
    let detail: String
    let icon: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.title2)
                    Text(key)
                        .font(.headline.monospaced())
                }
                .foregroundStyle(.white)
            }
            .frame(width: 86, height: 86)
            .shadow(color: (colors.first ?? .purple).opacity(0.2), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 5) {
                Text(button)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 124)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct KeyboardEditorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceHero(model: model)

                HStack {
                    Text("Button mappings")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if model.availableLayerCount > 1 {
                        Picker("Layer", selection: Binding(
                            get: { model.selectedLayer },
                            set: { model.selectedLayer = $0 }
                        )) {
                            ForEach(0 ..< model.availableLayerCount, id: \.self) { layer in
                                Text("Layer \(layer + 1)").tag(layer)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.editableButtons.indices, id: \.self) { buttonIndex in
                        ButtonMappingCard(model: model, buttonIndex: buttonIndex)
                    }
                }

                GroupBox("Profiles") {
                    HStack(spacing: 12) {
                        Button("Copy / Paste") { model.applyCopyPasteProfile() }
                            .buttonStyle(.bordered)
                        Button("Codex triggers · F13 / F16") { model.applyCodexTriggerProfile() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Text("Profiles stage values on the selected layer.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("SayoDevice O2L V2")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshDevice() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingDevice || model.isSaving)

                Button {
                    Task { await model.saveDevice() }
                } label: {
                    Label("Save to keyboard", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.deviceSnapshot == nil || model.isLoadingDevice || model.isSaving)
            }
        }
    }
}

private struct DeviceHero: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.85), .blue.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 86, height: 86)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(model.deviceSnapshot?.product ?? "SayoDevice O2L V2")
                        .font(.title2.weight(.bold))
                    Circle()
                        .fill(model.deviceSnapshot == nil ? Color.orange : Color.green)
                        .frame(width: 9, height: 9)
                }
                Text(model.deviceMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let snapshot = model.deviceSnapshot {
                    Text(String(format: "VID %04X · PID %04X · vendor report 02 · %@", snapshot.vendorID, snapshot.productID, snapshot.serialNumber))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if model.keyboardAccessStatus != .granted {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Open Input Monitoring") {
                        Task { await model.requestKeyboardAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Restart Keyboard Studio") {
                        model.restartApplication()
                    }
                    .controlSize(.small)
                }
            }
            if model.isLoadingDevice || model.isSaving {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct ButtonMappingCard: View {
    @ObservedObject var model: AppModel
    let buttonIndex: Int

    private var layerBinding: Binding<SayoKeyLayer> {
        Binding(
            get: { model.layer(for: buttonIndex) },
            set: { model.setLayer($0, for: buttonIndex) }
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Action", selection: layerBinding.mode) {
                    ForEach(SayoKeyModeCatalog.entries) { entry in
                        Text(entry.title).tag(entry.code)
                    }
                }

                Text(SayoKeyModeCatalog.entry(for: layerBinding.wrappedValue.mode).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if [UInt8(0), 1, 5].contains(layerBinding.wrappedValue.mode) {
                    Picker("Primary key", selection: keyBinding(at: 0)) {
                        ForEach(HIDKeyCatalog.entries) { entry in
                            Text(entry.name).tag(entry.code)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Modifiers")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            ForEach(HIDModifier.allCases) { modifier in
                                Toggle(modifier.title, isOn: modifierBinding(modifier))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                } else if layerBinding.wrappedValue.mode == 3 {
                    Picker("Media command", selection: layerBinding.modifier) {
                        ForEach(SayoMediaCatalog.entries) { entry in
                            Text(entry.name).tag(entry.code)
                        }
                    }
                } else if layerBinding.wrappedValue.mode == 8 {
                    Stepper("Password slot · \(Int(layerBinding.wrappedValue.modifier) + 1)", value: layerBinding.modifier, in: 0 ... 127)
                    Toggle("Press Return after typing", isOn: Binding(
                        get: { layerBinding.wrappedValue.keyCodes[0] == 0 },
                        set: { enabled in
                            var value = layerBinding.wrappedValue
                            value.keyCodes[0] = enabled ? 0 : 1
                            layerBinding.wrappedValue = value
                        }
                    ))
                    Stepper("Character interval · \(layerBinding.wrappedValue.keyCodes[1])", value: keyBinding(at: 1), in: 0 ... 255)
                } else if [UInt8(128), 129].contains(layerBinding.wrappedValue.mode) {
                    Stepper("Target layer · \(Int(layerBinding.wrappedValue.modifier) + 1)", value: layerBinding.modifier, in: 0 ... UInt8(max(0, model.availableLayerCount - 1)))
                } else if layerBinding.wrappedValue.mode == 2 {
                    Stepper("Mouse buttons mask · \(layerBinding.wrappedValue.modifier)", value: layerBinding.modifier, in: 0 ... 7)
                    Stepper("Horizontal · \(Int(Int8(bitPattern: layerBinding.wrappedValue.keyCodes[0])))", value: keyBinding(at: 0), in: 0 ... 255)
                    Stepper("Vertical · \(Int(Int8(bitPattern: layerBinding.wrappedValue.keyCodes[1])))", value: keyBinding(at: 1), in: 0 ... 255)
                    Stepper("Scroll · \(Int(Int8(bitPattern: layerBinding.wrappedValue.keyCodes[2])))", value: keyBinding(at: 2), in: 0 ... 255)
                }

                DisclosureGroup("Parameters & raw values") {
                    VStack(alignment: .leading, spacing: 10) {
                        if [UInt8(0), 1, 5].contains(layerBinding.wrappedValue.mode) {
                            Picker("Second key", selection: keyBinding(at: 1)) {
                                ForEach(HIDKeyCatalog.entries) { entry in
                                    Text(entry.name).tag(entry.code)
                                }
                            }
                            Picker("Third key", selection: keyBinding(at: 2)) {
                                ForEach(HIDKeyCatalog.entries) { entry in
                                    Text(entry.name).tag(entry.code)
                                }
                            }
                        }
                        HStack {
                            RawByteField(title: "P0", value: layerBinding.modifier)
                            RawByteField(title: "P1", value: keyBinding(at: 0))
                            RawByteField(title: "P2", value: keyBinding(at: 1))
                            RawByteField(title: "P3", value: keyBinding(at: 2))
                        }
                        Text(rawSummary(layerBinding.wrappedValue))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(8)
        } label: {
            HStack {
                Label("Button \(buttonIndex + 1)", systemImage: "square.fill")
                    .font(.headline)
                Spacer()
                Text(actionSummary(layerBinding.wrappedValue))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func modifierBinding(_ modifier: HIDModifier) -> Binding<Bool> {
        Binding(
            get: { layerBinding.wrappedValue.modifier & modifier.rawValue != 0 },
            set: { isEnabled in
                var value = layerBinding.wrappedValue
                if isEnabled {
                    value.modifier |= modifier.rawValue
                } else {
                    value.modifier &= ~modifier.rawValue
                }
                value.mode = 0
                layerBinding.wrappedValue = value
            }
        )
    }

    private func keyBinding(at index: Int) -> Binding<UInt8> {
        Binding(
            get: { layerBinding.wrappedValue.keyCodes[index] },
            set: { code in
                var value = layerBinding.wrappedValue
                value.keyCodes[index] = code
                layerBinding.wrappedValue = value
            }
        )
    }

    private func actionSummary(_ layer: SayoKeyLayer) -> String {
        guard [UInt8(0), 1, 5].contains(layer.mode) else {
            return SayoKeyModeCatalog.entry(for: layer.mode).title
        }
        let modifiers = HIDModifier.allCases
            .filter { layer.modifier & $0.rawValue != 0 }
            .map(\.title)
        return (modifiers + [HIDKeyCatalog.name(for: layer.keyCodes[0])]).joined(separator: " + ")
    }

    private func rawSummary(_ layer: SayoKeyLayer) -> String {
        let keys = layer.keyCodes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return String(format: "mode %02X · modifier %02X · keys %@", layer.mode, layer.modifier, keys)
    }
}

private struct RawByteField: View {
    let title: String
    @Binding var value: UInt8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("0", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
        }
    }
}

private struct CodexActivityView: View {
    @ObservedObject var model: AppModel
    @AppStorage("codexStatusLampEnabled") private var codexStatusLampEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.purple.opacity(0.14))
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .foregroundStyle(.purple)
                        .font(.title2)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex activity")
                        .font(.title2.weight(.semibold))
                    Text(model.activityMessage)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Status lamp", isOn: $codexStatusLampEnabled)
                    .toggleStyle(.switch)
                    .disabled(!model.supportsRGBLighting)
                    .help(model.supportsRGBLighting
                        ? "Blue means working; red means attention."
                        : "This firmware does not advertise Lighting v2 command 16.")
                switch model.notificationAuthorizationStatus {
                case .notDetermined:
                    Button("Enable macOS alerts") {
                        Task { await model.requestNotificationAccess() }
                    }
                case .denied:
                    Button("Open Notification Settings") {
                        model.openNotificationSettings()
                    }
                    .help("Notifications were previously denied; macOS will not show the prompt again.")
                case .authorized, .provisional, .ephemeral:
                    Label("Alerts enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                @unknown default:
                    EmptyView()
                }
                Button("Open Codex") { model.openCodex() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)

            Divider()

            if model.activities.isEmpty, model.isLoadingActivities {
                Spacer()
                ProgressView("Loading Codex summaries…")
                Spacer()
            } else {
                List(model.activities, selection: $model.selectedCodexReviewActivityID) { activity in
                    ActivityRow(activity: activity)
                        .padding(.vertical, 6)
                        .tag(activity.id)
                }
                .listStyle(.inset)
                .refreshable { await model.refreshActivities() }
            }
        }
        .onChange(of: codexStatusLampEnabled) { _, _ in
            Task { await model.codexStatusLampSettingChanged() }
        }
        .navigationTitle("Codex Activity")
        .toolbar {
            Button {
                Task { await model.refreshActivities() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingActivities)
        }
    }
}

private struct ActivityRow: View {
    let activity: CodexActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.compactSummary ?? "Codex task update")
                    .font(.headline)
                Text(activity.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(activity.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ProtocolView: View {
    let snapshot: SayoDeviceSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Recovered protocol")
                    .font(.largeTitle.bold())
                Text("The second keyboard is a composite USB HID device. Standard reports emit keys, pointer movement, and media controls; vendor report 0x02 carries the configuration protocol.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    protocolRow("Identity", "VID 8089 · PID 000C")
                    protocolRow("Vendor collection", "Usage page FF00 · usage 01")
                    protocolRow("Report", "ID 02 · 64 bytes · 63 data bytes")
                    protocolRow("Frame", "[report, command, length, payload…, trailer, zero padding]")
                    protocolRow("Request checksum", "8-bit sum of report + command + length + payload")
                    protocolRow("Response trailer", "Opaque on firmware 0x089A; framing and length remain validated")
                    protocolRow("Key map", "Command 22 · 16-byte header + up to 5 × 6-byte layers")
                    protocolRow("Commit", "Command 04 · payload 72 96")
                    if let snapshot {
                        protocolRow("Firmware", snapshot.firmwareVersion.map { String(format: "0x%04X", $0) } ?? "unknown")
                        protocolRow("Model code", snapshot.modelCode.map { String(format: "0x%04X", $0) } ?? "unknown")
                        protocolRow("Commands", snapshot.supportedCommands.map(String.init).joined(separator: ", "))
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                Text("Safety model")
                    .font(.title2.weight(.semibold))
                Text("Reload sends read requests only. Mapping changes stay in the app until Save to keyboard is pressed. Save writes each mapping, validates the echoed response, then issues the flash-commit command.")
                    .foregroundStyle(.secondary)

                Text("Reproducible probe")
                    .font(.title2.weight(.semibold))
                Text("swift run sayo-probe")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Protocol")
    }

    @ViewBuilder
    private func protocolRow(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).fontWeight(.semibold)
            Text(value).font(.body.monospaced()).textSelection(.enabled)
        }
    }
}
