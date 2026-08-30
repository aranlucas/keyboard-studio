import AppKit
import KeyboardCore
import SwiftUI

struct LightingStudioView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                featureHeader(
                    title: "Lighting",
                    subtitle: "Every Lighting v2 effect and all six ten-color palettes exposed by this O2L firmware.",
                    icon: "lightbulb.led.fill",
                    color: .orange
                )

                if model.lightingConfigurations.isEmpty {
                    ContentUnavailableView("No Lighting v2 records", systemImage: "lightbulb.slash")
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(model.lightingConfigurations.indices, id: \.self) { index in
                            LightingCard(model: model, index: index)
                        }
                    }
                }

                GroupBox("Color tables") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Effects can loop or randomly select these palettes. Each table preserves the firmware-owned prefix and trailer bytes.")
                            .foregroundStyle(.secondary)
                        ForEach(model.colorTables.indices, id: \.self) { tableIndex in
                            PaletteRow(model: model, tableIndex: tableIndex)
                            if tableIndex != model.colorTables.indices.last { Divider() }
                        }
                    }
                    .padding(8)
                }

                featureStatusBar(model.configurationMessage)
            }
            .padding(24)
            .frame(maxWidth: 1050, alignment: .leading)
        }
        .navigationTitle("Lighting")
        .toolbar {
            ToolbarItemGroup {
                Button("Save Effects") { Task { await model.saveLighting() } }
                    .disabled(model.lightingConfigurations.isEmpty || model.isSaving)
                Button("Save Palettes") { Task { await model.saveColorTables() } }
                    .disabled(model.colorTables.isEmpty || model.isSaving)
            }
        }
    }
}

private struct LightingCard: View {
    @ObservedObject var model: AppModel
    let index: Int

    private var configuration: Binding<SayoLightingV2Configuration> {
        $model.lightingConfigurations[index]
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Effect", selection: configuration.mode) {
                    ForEach(SayoLightingEffect.allCases) { effect in
                        Text(effect.title).tag(effect.rawValue)
                    }
                }
                Picker("Color source", selection: valueBinding(0)) {
                    Text("Direct color").tag(UInt8(0))
                    Text("Loop palette").tag(UInt8(16))
                    Text("Random palette").tag(UInt8(32))
                    Text("Random color").tag(UInt8(48))
                }
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .disabled(valueBinding(0).wrappedValue != 0)
                Picker("Speed", selection: valueBinding(1)) {
                    Text("8×").tag(UInt8(0))
                    Text("4×").tag(UInt8(64))
                    Text("2×").tag(UInt8(128))
                    Text("1×").tag(UInt8(192))
                }
                Picker("Key event", selection: valueBinding(2)) {
                    Text("Independent").tag(UInt8(0))
                    Text("Press on · release off").tag(UInt8(1))
                    Text("Press off · release on").tag(UInt8(2))
                    Text("Press fade out · release fade in").tag(UInt8(3))
                    Text("Press fade in · release fade out").tag(UInt8(4))
                    Text("Run after press").tag(UInt8(5))
                    Text("Run after release").tag(UInt8(6))
                }
                Stepper("On hold · \(valueBinding(6).wrappedValue)", value: valueBinding(6), in: 0 ... 255)
                Stepper("Off hold · \(valueBinding(7).wrappedValue)", value: valueBinding(7), in: 0 ... 255)
                Stepper("Palette · \(valueBinding(8).wrappedValue + 1)", value: valueBinding(8), in: 0 ... 5)
                DisclosureGroup("Raw record") {
                    Text(configuration.wrappedValue.values.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            Label("Button \(index + 1)", systemImage: "lightbulb.fill")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    private func valueBinding(_ valueIndex: Int) -> Binding<UInt8> {
        Binding(
            get: {
                guard configuration.wrappedValue.values.indices.contains(valueIndex) else { return 0 }
                return configuration.wrappedValue.values[valueIndex]
            },
            set: { newValue in
                var updated = configuration.wrappedValue
                guard updated.values.indices.contains(valueIndex) else { return }
                updated.values[valueIndex] = newValue
                configuration.wrappedValue = updated
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let values = configuration.wrappedValue.values
                guard values.count >= 6 else { return .black }
                return Color(
                    red: Double(values[3]) / 255,
                    green: Double(values[4]) / 255,
                    blue: Double(values[5]) / 255
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                var updated = configuration.wrappedValue
                guard updated.values.count >= 6 else { return }
                updated.values[3] = UInt8(clamping: Int(converted.redComponent * 255))
                updated.values[4] = UInt8(clamping: Int(converted.greenComponent * 255))
                updated.values[5] = UInt8(clamping: Int(converted.blueComponent * 255))
                configuration.wrappedValue = updated
            }
        )
    }
}

private struct PaletteRow: View {
    @ObservedObject var model: AppModel
    let tableIndex: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("Table \(tableIndex + 1)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 64, alignment: .leading)
            ForEach(0 ..< 10, id: \.self) { colorIndex in
                ColorPicker("", selection: colorBinding(colorIndex), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 32)
            }
            Spacer()
        }
    }

    private func colorBinding(_ colorIndex: Int) -> Binding<Color> {
        Binding(
            get: {
                let values = model.colorTables[tableIndex].values
                let offset = 1 + colorIndex * 3
                guard values.count > offset + 2 else { return .black }
                return Color(
                    red: Double(values[offset]) / 255,
                    green: Double(values[offset + 1]) / 255,
                    blue: Double(values[offset + 2]) / 255
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                let offset = 1 + colorIndex * 3
                guard model.colorTables[tableIndex].values.count > offset + 2 else { return }
                model.colorTables[tableIndex].values[offset] = UInt8(clamping: Int(converted.redComponent * 255))
                model.colorTables[tableIndex].values[offset + 1] = UInt8(clamping: Int(converted.greenComponent * 255))
                model.colorTables[tableIndex].values[offset + 2] = UInt8(clamping: Int(converted.blueComponent * 255))
            }
        )
    }
}

struct MacrosStudioView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                featureHeader(
                    title: "Text & Passwords",
                    subtitle: "Native editors for the keyboard's one-key text and password storage. Passwords are loaded only on request.",
                    icon: "text.cursor",
                    color: .blue
                )

                GroupBox("One-key text") {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.stringSlots.isEmpty {
                            Text("No text slots were returned.").foregroundStyle(.secondary)
                        } else {
                            Picker("Slot", selection: $model.selectedStringSlot) {
                                ForEach(model.stringSlots.indices, id: \.self) { index in
                                    Text("Text \(index + 1)").tag(index)
                                }
                            }
                            .frame(maxWidth: 280)
                            TextField("Text (up to 28 ASCII characters)", text: Binding(
                                get: { model.textValue(for: min(model.selectedStringSlot, model.stringSlots.count - 1)) },
                                set: { model.setTextValue($0, for: min(model.selectedStringSlot, model.stringSlots.count - 1)) }
                            ))
                            HStack {
                                Text("Bind a key to One-key text and use this slot number as its first parameter.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Save Selected Text") { Task { await model.saveStrings() } }
                                    .disabled(model.isSaving)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("One-key passwords") {
                    VStack(alignment: .leading, spacing: 14) {
                        if !model.secretsAreLoaded {
                            Text("Password values are deliberately not read during normal device refresh or included in backups by default.")
                                .foregroundStyle(.secondary)
                            Button("Load Password Slots") { Task { await model.loadSecrets() } }
                                .buttonStyle(.borderedProminent)
                        } else if !model.passwordSlots.isEmpty {
                            Picker("Slot", selection: $model.selectedPasswordSlot) {
                                ForEach(model.passwordSlots.indices, id: \.self) { index in
                                    Text("Password \(index + 1)").tag(index)
                                }
                            }
                            .frame(maxWidth: 280)
                            SecureField("Password", text: $model.passwordSlots[min(model.selectedPasswordSlot, model.passwordSlots.count - 1)].name)
                            HStack {
                                Text("The value is stored on the keyboard, not in macOS Keychain.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Save Selected Password") { Task { await model.savePasswords() } }
                            }
                        }
                    }
                    .padding(8)
                }

                featureStatusBar(model.configurationMessage)
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle("Text & Passwords")
    }
}

struct ScriptsStudioView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                featureHeader(
                    title: "Scripts",
                    subtitle: "The device VM can send keyboard, mouse, media, and LED operations with delays, loops, branches, registers, and threads.",
                    icon: "chevron.left.forwardslash.chevron.right",
                    color: .purple
                )

                GroupBox("Script slots") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.scriptSlots.indices, id: \.self) { index in
                            HStack {
                                Text("Script \(index + 1)").frame(width: 70, alignment: .leading)
                                TextField("Name", text: $model.scriptSlots[index].name)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Quick script builder") {
                    HStack(spacing: 14) {
                        Picker("Slot", selection: $model.selectedScriptSlot) {
                            ForEach(model.scriptSlots.indices, id: \.self) { index in
                                Text("Script \(index + 1)").tag(index)
                            }
                        }
                        Picker("Template", selection: $model.selectedScriptPreset) {
                            ForEach(ScriptPreset.allCases) { preset in Text(preset.title).tag(preset) }
                        }
                        Picker("Key", selection: $model.selectedScriptKey) {
                            ForEach(HIDKeyCatalog.entries) { entry in Text(entry.name).tag(entry.code) }
                        }
                        .disabled(model.selectedScriptPreset == .codexBlue)
                        Spacer()
                        Button("Build") {
                            model.applyScriptTemplate(slot: model.selectedScriptSlot, template: model.selectedScriptPreset, key: model.selectedScriptKey)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.scriptSlots.isEmpty)
                    }
                    .padding(8)
                }

                GroupBox("Bytecode image") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: scriptHexBinding)
                            .font(.body.monospaced())
                            .frame(minHeight: 170)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        Text("Hex bytes are the firmware's native VM format. Template output always releases keys and terminates cleanly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                featureStatusBar(model.configurationMessage)
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("Scripts")
        .toolbar {
            Button("Save Scripts") { Task { await model.saveScripts() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.scriptSlots.isEmpty || model.isSaving)
        }
    }

    private var scriptHexBinding: Binding<String> {
        Binding(
            get: { model.scriptImage.map { String(format: "%02X", $0) }.joined(separator: " ") },
            set: { value in
                let tokens = value.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                let decoded = tokens.compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
                if decoded.count == tokens.count { model.scriptImage = decoded }
            }
        )
    }
}

struct DeviceSettingsStudioView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                featureHeader(
                    title: "Device",
                    subtitle: "Identity, name, firmware capabilities, and guarded maintenance controls.",
                    icon: "gearshape.2.fill",
                    color: .gray
                )

                GroupBox("Device name") {
                    HStack {
                        TextField("Device name", text: $model.editableDeviceName)
                            .frame(maxWidth: 420)
                        Button("Save Name") { Task { await model.saveDeviceName() } }
                            .disabled(model.editableDeviceName.isEmpty || model.isSaving)
                        Spacer()
                    }
                    .padding(8)
                }

                if let identity = model.deviceIdentityConfiguration {
                    GroupBox("USB identity") {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
                            GridRow { Text("Vendor ID").bold(); Text(String(format: "%04X", identity.vendorID)).monospaced() }
                            GridRow { Text("Product ID").bold(); Text(String(format: "%04X", identity.productID)).monospaced() }
                            GridRow { Text("Firmware").bold(); Text(model.deviceSnapshot?.firmwareVersion.map { String(format: "0x%04X", $0) } ?? "Unknown").monospaced() }
                            GridRow { Text("Model code").bold(); Text(model.deviceSnapshot?.modelCode.map { String(format: "0x%04X", $0) } ?? "Unknown").monospaced() }
                            GridRow { Text("Commands").bold(); Text(model.deviceSnapshot?.supportedCommands.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "").monospaced() }
                        }
                        .padding(8)
                    }
                }

                GroupBox("Maintenance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Firmware update, bootloader, recovery, device lock, and factory reset are detected capabilities.", systemImage: "lock.shield")
                            .font(.headline)
                        Text("They are not sent as blind raw commands. Firmware packages must be verified against model code 0002, and reset or lock operations require a recoverable backup and an explicit confirmation flow.")
                            .foregroundStyle(.secondary)
                        Link("Open official firmware catalog", destination: URL(string: "https://app.sayodevice.com/")!)
                    }
                    .padding(8)
                }

                featureStatusBar(model.configurationMessage)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Device")
    }
}

struct BackupStudioView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                featureHeader(
                    title: "Backup & Restore",
                    subtitle: "Portable JSON backups preserve key layers, opaque metadata, lighting, palettes, text, scripts, and device naming.",
                    icon: "externaldrive.fill.badge.timemachine",
                    color: .green
                )

                GroupBox("Create backup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Include password values", isOn: $model.includeSecretsInBackup)
                            .disabled(!model.secretsAreLoaded)
                        Text(model.secretsAreLoaded
                            ? "Password values are excluded unless you opt in. Included files should be treated as secrets."
                            : "Load password slots from Text & Passwords before they can be included.")
                            .foregroundStyle(.secondary)
                        Button("Export Backup…") { Task { await model.exportBackup() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.deviceSnapshot == nil)
                    }
                    .padding(8)
                }

                GroupBox("Restore") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Import validates the backup format and model code, then stages values in the app. Nothing is written until you review the relevant page and press Save.")
                            .foregroundStyle(.secondary)
                        Button("Import Backup…") { model.importBackup() }
                    }
                    .padding(8)
                }

                featureStatusBar(model.configurationMessage)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Backup & Restore")
    }
}

@ViewBuilder
private func featureHeader(title: String, subtitle: String, icon: String, color: Color) -> some View {
    HStack(spacing: 16) {
        Image(systemName: icon)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 18))
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
    }
}

@ViewBuilder
private func featureStatusBar(_ message: String) -> some View {
    Label(message, systemImage: "info.circle.fill")
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
}
