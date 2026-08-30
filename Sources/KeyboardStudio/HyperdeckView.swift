import AppKit
import KeyboardCore
import SwiftUI

private enum HyperdeckPage: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case profiles = "Profiles"
    case recipes = "Recipes"
    case clipboard = "Clipboard"
    case focus = "Focus"
    case log = "Event Log"

    var id: String { rawValue }
}

struct HyperdeckStudioView: View {
    let controller: HyperdeckController
    @AppStorage("selectedHyperdeckPage") private var pageRawValue = HyperdeckPage.dashboard.rawValue

    private var page: HyperdeckPage {
        get { HyperdeckPage(rawValue: pageRawValue) ?? .dashboard }
        nonmutating set { pageRawValue = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HyperdeckHeader(controller: controller)

            Picker("Hyperdeck page", selection: Binding(
                get: { page },
                set: { page = $0 }
            )) {
                ForEach(HyperdeckPage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider()

            Group {
                switch page {
                case .dashboard: HyperdeckDashboard(controller: controller)
                case .profiles: HyperdeckProfilesView(controller: controller)
                case .recipes: HyperdeckRecipesView(controller: controller)
                case .clipboard: HyperdeckClipboardView(controller: controller)
                case .focus: HyperdeckFocusView(controller: controller)
                case .log: HyperdeckLogView(controller: controller)
                }
            }
        }
        .navigationTitle("Hyperdeck")
    }
}

private struct HyperdeckHeader: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Two-Key Hyperdeck", systemImage: "rectangle.2.swap")
                    .font(.title.bold())
                Text("Ten gestures · smart profiles · permission-safe native actions")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Label(controller.activeProfile?.name ?? "No profile", systemImage: "circle.fill")
                    .foregroundStyle(.purple)
                Text(controller.activeApplicationName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

private struct HyperdeckDashboard: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    metricCard(
                        title: controller.isListening ? "Listening" : "Unavailable",
                        detail: "F13 + F16",
                        icon: controller.isListening ? "wave.3.right.circle.fill" : "exclamationmark.triangle.fill",
                        color: controller.isListening ? .green : .red
                    )
                    metricCard(
                        title: controller.activeProfile?.name ?? "No profile",
                        detail: controller.activeBundleIdentifier.isEmpty ? "Fallback context" : controller.activeBundleIdentifier,
                        icon: "square.stack.3d.up.fill",
                        color: .purple
                    )
                    metricCard(
                        title: controller.formattedFocusTime,
                        detail: controller.focusState.isRunning ? "Focus running" : "Focus paused",
                        icon: "timer",
                        color: controller.focusState.isRunning ? .green : .orange
                    )
                }

                GroupBox("Gesture Lab") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Test any classification without pressing the hardware. Physical events use the same pipeline and are logged individually.")
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                            ForEach(HyperdeckGesture.allCases) { gesture in
                                Button {
                                    controller.testGesture(gesture)
                                } label: {
                                    HStack {
                                        Text(gesture.compactSymbol)
                                            .font(.body.monospaced().bold())
                                            .frame(width: 48)
                                        Text(gesture.title)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Test \(gesture.title)")
                            }
                        }
                    }
                    .padding(8)
                }

                GestureTimingEditor(controller: controller)

                Label(controller.statusMessage, systemImage: "info.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
            .frame(maxWidth: 1050, alignment: .leading)
        }
    }

    private func metricCard(title: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

private struct GestureTimingEditor: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        GroupBox("Gesture timing") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                timingRow("Chord window", keyPath: \.chordWindow, range: 0.02 ... 0.25, format: "%.0f ms", multiplier: 1000)
                timingRow("Double / sequence", keyPath: \.sequenceWindow, range: 0.12 ... 0.8, format: "%.0f ms", multiplier: 1000)
                timingRow("Single-key hold", keyPath: \.holdThreshold, range: 0.2 ... 2, format: "%.0f ms", multiplier: 1000)
                timingRow("Both-key hold", keyPath: \.bothHoldThreshold, range: 0.45 ... 4, format: "%.2f s", multiplier: 1)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func timingRow(
        _ title: String,
        keyPath: WritableKeyPath<HyperdeckGestureTiming, TimeInterval>,
        range: ClosedRange<Double>,
        format: String,
        multiplier: Double
    ) -> some View {
        GridRow {
            Text(title).frame(width: 130, alignment: .leading)
            Slider(value: Binding(
                get: { controller.configuration.timing[keyPath: keyPath] },
                set: { value in
                    var timing = controller.configuration.timing
                    timing[keyPath: keyPath] = value
                    controller.updateTiming(timing)
                }
            ), in: range)
            .frame(minWidth: 300)
            Text(String(format: format, controller.configuration.timing[keyPath: keyPath] * multiplier))
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)
        }
    }
}

private struct HyperdeckProfilesView: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(controller.configuration.profiles, selection: $controller.selectedProfileID) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name).font(.headline)
                        Text(profile.bundleIdentifiers.isEmpty ? "Fallback profile" : profile.bundleIdentifiers.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(profile.id)
                }
                Divider()
                HStack {
                    Button {
                        let profile = HyperdeckProfile(name: "New Profile")
                        controller.updateProfile(profile)
                    } label: { Label("Add", systemImage: "plus") }
                    Spacer()
                    Button(role: .destructive) {
                        if let id = controller.selectedProfileID { controller.deleteProfile(id: id) }
                    } label: { Image(systemName: "trash") }
                    .disabled(controller.configuration.profiles.count <= 1)
                }
                .padding(10)
            }
            .frame(minWidth: 240, idealWidth: 270)

            if let profile = controller.configuration.profiles.first(where: { $0.id == controller.selectedProfileID }) {
                HyperdeckProfileEditor(controller: controller, initialProfile: profile)
                    .id(profile.id)
            } else {
                ContentUnavailableView("Select a profile", systemImage: "square.stack.3d.up")
            }
        }
    }
}

private struct HyperdeckProfileEditor: View {
    @ObservedObject var controller: HyperdeckController
    @StateObject private var draft: HyperdeckProfileDraft

    init(controller: HyperdeckController, initialProfile: HyperdeckProfile) {
        self.controller = controller
        _draft = StateObject(wrappedValue: HyperdeckProfileDraft(profile: initialProfile))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Smart Profile").font(.title.bold())
                TextField("Profile name", text: $draft.profile.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Bundle identifiers, comma separated", text: bundleIdentifiersBinding)
                    .textFieldStyle(.roundedBorder)
                Text("Leave bundle identifiers empty for the fallback profile. Matching uses NSWorkspace and requires no Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Unassigned gestures inherit the matching recipe from the fallback profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ColorPicker("Profile feedback color", selection: profileColorBinding, supportsOpacity: false)

                Divider()
                Text("Gesture assignments").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(HyperdeckGesture.allCases) { gesture in
                        GridRow {
                            Text(gesture.compactSymbol).monospaced().bold().frame(width: 54)
                            Text(gesture.title).frame(width: 140, alignment: .leading)
                            Picker("Recipe", selection: assignmentBinding(gesture)) {
                                Text("Unassigned").tag(nil as UUID?)
                                ForEach(controller.configuration.recipes) { recipe in
                                    Label(recipe.name, systemImage: recipe.symbol).tag(recipe.id as UUID?)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 260)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Save Profile") { controller.updateProfile(draft.profile) }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var bundleIdentifiersBinding: Binding<String> {
        Binding(
            get: { draft.profile.bundleIdentifiers.joined(separator: ", ") },
            set: { value in
                draft.profile.bundleIdentifiers = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func assignmentBinding(_ gesture: HyperdeckGesture) -> Binding<UUID?> {
        Binding(
            get: { draft.profile.assignments[gesture] },
            set: { value in draft.profile.assignments[gesture] = value }
        )
    }

    private var profileColorBinding: Binding<Color> {
        Binding(
            get: { Color(red: Double(draft.profile.color.red) / 255, green: Double(draft.profile.color.green) / 255, blue: Double(draft.profile.color.blue) / 255) },
            set: { draft.profile.color = $0.hyperdeckRGB }
        )
    }
}

private final class HyperdeckProfileDraft: ObservableObject {
    @Published var profile: HyperdeckProfile

    init(profile: HyperdeckProfile) {
        self.profile = profile
    }
}

private struct HyperdeckRecipesView: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(controller.configuration.recipes, selection: $controller.selectedRecipeID) { recipe in
                    Label(recipe.name, systemImage: recipe.symbol).tag(recipe.id)
                }
                Divider()
                HStack {
                    Button {
                        controller.updateRecipe(HyperdeckRecipe(name: "New Recipe", steps: [.init(kind: .none)]))
                    } label: { Label("Add", systemImage: "plus") }
                    Spacer()
                    Button(role: .destructive) {
                        if let id = controller.selectedRecipeID { controller.deleteRecipe(id: id) }
                    } label: { Image(systemName: "trash") }
                }
                .padding(10)
            }
            .frame(minWidth: 240, idealWidth: 270)

            if let recipe = controller.configuration.recipes.first(where: { $0.id == controller.selectedRecipeID }) {
                HyperdeckRecipeEditor(controller: controller, initialRecipe: recipe)
                    .id(recipe.id)
            } else {
                ContentUnavailableView("Select a recipe", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

private struct HyperdeckRecipeEditor: View {
    @ObservedObject var controller: HyperdeckController
    @StateObject private var draft: HyperdeckRecipeDraft

    init(controller: HyperdeckController, initialRecipe: HyperdeckRecipe) {
        self.controller = controller
        _draft = StateObject(wrappedValue: HyperdeckRecipeDraft(recipe: initialRecipe))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Multi-Action Recipe").font(.title.bold())
                HStack {
                    TextField("Recipe name", text: $draft.recipe.name)
                    TextField("SF Symbol", text: $draft.recipe.symbol).frame(width: 180)
                }
                .textFieldStyle(.roundedBorder)

                Text("Steps run from top to bottom. Executables must be explicit absolute paths, compiled binaries only, and are launched directly—never through an interpreter or shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(draft.recipe.steps.enumerated()), id: \.element.id) { index, _ in
                    actionStepEditor(index)
                }

                Button {
                    draft.recipe.steps.append(.init(kind: .none))
                } label: { Label("Add Step", systemImage: "plus.circle.fill") }

                HStack {
                    Button("Test Recipe") {
                        controller.updateRecipe(draft.recipe)
                        controller.execute(recipeID: draft.recipe.id)
                    }
                    Spacer()
                    Button("Save Recipe") { controller.updateRecipe(draft.recipe) }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.recipe.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actionStepEditor(_ index: Int) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Action", selection: $draft.recipe.steps[index].kind) {
                        ForEach(HyperdeckActionKind.allCases) { Text($0.title).tag($0) }
                    }
                    Spacer()
                    Button(role: .destructive) { draft.recipe.steps.remove(at: index) } label: {
                        Image(systemName: "trash")
                    }
                }
                actionFields(index)
            }
            .padding(6)
        } label: {
            Text("Step \(index + 1)").font(.headline)
        }
    }

    @ViewBuilder
    private func actionFields(_ index: Int) -> some View {
        let kind = draft.recipe.steps[index].kind
        switch kind {
        case .openApplication:
            TextField("Bundle identifier or absolute .app path", text: $draft.recipe.steps[index].value)
        case .openURL:
            TextField("https://…", text: $draft.recipe.steps[index].value)
        case .runShortcut:
            TextField("Shortcut name", text: $draft.recipe.steps[index].value)
            Toggle("Pass clipboard as input", isOn: $draft.recipe.steps[index].passesClipboard)
        case .delay:
            HStack {
                Slider(value: $draft.recipe.steps[index].duration, in: 0 ... 30, step: 0.25)
                Text("\(draft.recipe.steps[index].duration, specifier: "%.2f") s").monospacedDigit().frame(width: 70)
            }
        case .copyText:
            TextEditor(text: $draft.recipe.steps[index].value).frame(minHeight: 70)
        case .showNotification:
            TextField("Notification title", text: $draft.recipe.steps[index].value)
            TextField("Notification body", text: $draft.recipe.steps[index].detail)
        case .setRGB:
            ColorPicker("Feedback color", selection: stepColorBinding(index), supportsOpacity: false)
            Text("The color is volatile and normal status lighting is restored automatically.")
                .font(.caption).foregroundStyle(.secondary)
        case .runExecutable:
            HStack {
                TextField("Absolute executable path", text: $draft.recipe.steps[index].value)
                Button("Choose…") { chooseExecutable(index) }
            }
            TextField("Arguments separated by new lines", text: argumentsBinding(index))
        case .none:
            Text("This step intentionally performs no action.").foregroundStyle(.secondary)
        default:
            Text(kind.title).foregroundStyle(.secondary)
        }
    }

    private func stepColorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let color = draft.recipe.steps[index].color
                return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
            },
            set: { draft.recipe.steps[index].color = $0.hyperdeckRGB }
        )
    }

    private func argumentsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.recipe.steps[index].arguments.joined(separator: "\n") },
            set: { draft.recipe.steps[index].arguments = $0.split(separator: "\n").map(String.init) }
        )
    }

    private func chooseExecutable(_ index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.recipe.steps[index].value = url.path
    }
}

private final class HyperdeckRecipeDraft: ObservableObject {
    @Published var recipe: HyperdeckRecipe

    init(recipe: HyperdeckRecipe) {
        self.recipe = recipe
    }
}

private struct HyperdeckClipboardView: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clipboard Deck").font(.title.bold())
                    Text("Opt-in, text-only, in-memory history. Nothing is persisted or pasted synthetically.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Monitor clipboard", isOn: Binding(
                    get: { controller.configuration.clipboardMonitoringEnabled },
                    set: { controller.setClipboardMonitoring($0) }
                ))
                .toggleStyle(.switch)
            }
            .padding(24)
            Divider()

            HSplitView {
                List(controller.clipboardItems, selection: $controller.selectedClipboardItemID) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).lineLimit(2)
                        Text(item.capturedAt, style: .time)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
                .frame(minWidth: 280)

                VStack(alignment: .leading, spacing: 14) {
                    if let item = controller.selectedClipboardItem {
                        ScrollView {
                            Text(item.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(12)
                        }
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Button("Previous") { controller.selectPreviousClipboardItem() }
                            Button("Next") { controller.selectNextClipboardItem() }
                            Button("Copy Selected") { controller.copySelectedClipboardItem() }
                                .buttonStyle(.borderedProminent)
                        }
                        HStack {
                            ForEach(HyperdeckClipboardTransform.allCases) { transform in
                                Button(transform.title) { controller.transformSelectedClipboardItem(transform) }
                            }
                        }
                    } else {
                        ContentUnavailableView("No clipboard text", systemImage: "clipboard", description: Text("Enable monitoring, then copy text in any app."))
                    }
                    Spacer()
                    Button("Clear In-Memory History", role: .destructive) { controller.clearClipboardHistory() }
                }
                .padding(20)
                .frame(minWidth: 420)
            }
        }
    }
}

private struct HyperdeckFocusView: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 18)
                Circle()
                    .trim(from: 0, to: controller.focusState.progress)
                    .stroke(controller.focusState.remaining <= 60 ? Color.orange : Color.green, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 8) {
                    Text(controller.formattedFocusTime)
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(controller.focusState.isRunning ? "Focusing" : "Ready")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 280, height: 280)

            HStack {
                Button(controller.focusState.isRunning ? "Pause" : "Start") { controller.toggleFocus() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Reset") { controller.resetFocus() }
                    .controlSize(.large)
            }

            Stepper(
                "Session length · \(controller.configuration.focusMinutes) minutes",
                value: Binding(
                    get: { controller.configuration.focusMinutes },
                    set: { controller.setFocusMinutes($0) }
                ),
                in: 1 ... 180
            )
            .frame(width: 310)

            Text("Completed this launch: \(controller.focusState.completedSessions)")
                .foregroundStyle(.secondary)
            Text("While running, Button 1 is green and turns orange for the last minute. Completion briefly lights Button 2 red, then restores Codex status lighting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HyperdeckLogView: View {
    @ObservedObject var controller: HyperdeckController

    var body: some View {
        List(controller.runtimeEvents) { event in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.isError ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                    .foregroundStyle(event.isError ? .red : .purple)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.headline)
                    Text(event.detail).foregroundStyle(.secondary)
                    Text(event.date, format: .dateTime.hour().minute().second())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
        }
        .overlay {
            if controller.runtimeEvents.isEmpty {
                ContentUnavailableView("No Hyperdeck events", systemImage: "waveform.path.ecg", description: Text("Press either physical key or use Gesture Lab."))
            }
        }
    }
}

private extension Color {
    var hyperdeckRGB: HyperdeckRGBColor {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return .purple }
        return HyperdeckRGBColor(
            red: UInt8(clamping: Int(color.redComponent * 255)),
            green: UInt8(clamping: Int(color.greenComponent * 255)),
            blue: UInt8(clamping: Int(color.blueComponent * 255))
        )
    }
}
