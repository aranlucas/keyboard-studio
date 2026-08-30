import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("activityRefreshInterval") private var refreshInterval = 15.0
    @AppStorage("codexStatusLampEnabled") private var codexStatusLampEnabled = true

    var body: some View {
        Form {
            Section("Codex activity") {
                Slider(value: $refreshInterval, in: 5 ... 60, step: 5) {
                    Text("Refresh every \(refreshInterval, specifier: "%.0f") seconds")
                }
                Text("Refresh every \(refreshInterval, specifier: "%.0f") seconds")
                    .foregroundStyle(.secondary)
                Toggle("Use the keyboard as a Codex status lamp", isOn: $codexStatusLampEnabled)
                    .disabled(!model.supportsRGBLighting)
                    .help(model.supportsRGBLighting
                        ? "Button 1 is blue while Codex works; Button 2 is red when attention is needed."
                        : "This firmware does not advertise Lighting v2 command 16.")
                Text("The status colors are volatile, never committed to flash, and normal lighting is restored when the lamp clears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: codexStatusLampEnabled) { _, _ in
            Task { await model.codexStatusLampSettingChanged() }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 430, height: 230)
    }
}
