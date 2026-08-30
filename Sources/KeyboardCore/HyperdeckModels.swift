import Foundation

public enum HyperdeckKey: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case left
    case right

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .left: "Left key"
        case .right: "Right key"
        }
    }
}

public enum HyperdeckKeyPhase: String, Codable, Sendable {
    case down
    case up
}

public struct HyperdeckPhysicalEvent: Equatable, Sendable {
    public var key: HyperdeckKey
    public var phase: HyperdeckKeyPhase
    public var timestamp: TimeInterval

    public init(key: HyperdeckKey, phase: HyperdeckKeyPhase, timestamp: TimeInterval) {
        self.key = key
        self.phase = phase
        self.timestamp = timestamp
    }
}

public enum HyperdeckGesture: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case leftTap
    case rightTap
    case leftHold
    case rightHold
    case leftDoubleTap
    case rightDoubleTap
    case bothTap
    case bothHold
    case leftThenRight
    case rightThenLeft

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftTap: "Left tap"
        case .rightTap: "Right tap"
        case .leftHold: "Left hold"
        case .rightHold: "Right hold"
        case .leftDoubleTap: "Left double-tap"
        case .rightDoubleTap: "Right double-tap"
        case .bothTap: "Both keys"
        case .bothHold: "Both-key hold"
        case .leftThenRight: "Left → Right"
        case .rightThenLeft: "Right → Left"
        }
    }

    public var compactSymbol: String {
        switch self {
        case .leftTap: "L"
        case .rightTap: "R"
        case .leftHold: "L—"
        case .rightHold: "R—"
        case .leftDoubleTap: "L×2"
        case .rightDoubleTap: "R×2"
        case .bothTap: "L+R"
        case .bothHold: "L+R—"
        case .leftThenRight: "L→R"
        case .rightThenLeft: "R→L"
        }
    }
}

public struct HyperdeckGestureTiming: Codable, Equatable, Sendable {
    public var chordWindow: TimeInterval
    public var sequenceWindow: TimeInterval
    public var holdThreshold: TimeInterval
    public var bothHoldThreshold: TimeInterval

    public init(
        chordWindow: TimeInterval = 0.06,
        sequenceWindow: TimeInterval = 0.25,
        holdThreshold: TimeInterval = 0.45,
        bothHoldThreshold: TimeInterval = 1.5
    ) {
        self.chordWindow = chordWindow
        self.sequenceWindow = sequenceWindow
        self.holdThreshold = holdThreshold
        self.bothHoldThreshold = bothHoldThreshold
    }

    public mutating func normalize() {
        chordWindow = min(max(chordWindow, 0.02), 0.25)
        sequenceWindow = min(max(sequenceWindow, 0.12), 0.8)
        holdThreshold = min(max(holdThreshold, chordWindow, 0.2), 2)
        bothHoldThreshold = min(max(bothHoldThreshold, holdThreshold), 4)
    }
}

/// Pure, monotonic-time state machine. Runtime code sleeps until `nextDeadline`
/// and then calls `flush(at:)`, allowing holds and deferred taps to fire without
/// a continuously polling timer.
public struct HyperdeckGestureRecognizer: Sendable {
    public var timing: HyperdeckGestureTiming

    private var downSince: [HyperdeckKey: TimeInterval] = [:]
    private var emittedHolds: Set<HyperdeckKey> = []
    private var chordStartedAt: TimeInterval?
    private var chordWasEmitted = false
    private var pendingTap: (key: HyperdeckKey, releasedAt: TimeInterval)?

    public init(timing: HyperdeckGestureTiming = .init()) {
        var timing = timing
        timing.normalize()
        self.timing = timing
    }

    public mutating func updateTiming(_ timing: HyperdeckGestureTiming) {
        var timing = timing
        timing.normalize()
        self.timing = timing
        reset()
    }

    public mutating func handle(_ event: HyperdeckPhysicalEvent) -> [HyperdeckGesture] {
        var gestures = flush(at: event.timestamp)
        switch event.phase {
        case .down:
            guard downSince[event.key] == nil else { return gestures }
            downSince[event.key] = event.timestamp
            let other: HyperdeckKey = event.key == .left ? .right : .left
            if let otherDown = downSince[other],
               !emittedHolds.contains(other),
               event.timestamp - otherDown <= timing.chordWindow
            {
                chordStartedAt = min(event.timestamp, otherDown)
                chordWasEmitted = false
                pendingTap = nil
            }

        case .up:
            guard let pressedAt = downSince.removeValue(forKey: event.key) else { return gestures }

            if let chordStartedAt {
                if downSince.isEmpty {
                    if !chordWasEmitted {
                        gestures.append(event.timestamp - chordStartedAt >= timing.bothHoldThreshold ? .bothHold : .bothTap)
                    }
                    self.chordStartedAt = nil
                    chordWasEmitted = false
                    emittedHolds.removeAll()
                }
                return gestures
            }

            if emittedHolds.remove(event.key) != nil {
                return gestures
            }

            if event.timestamp - pressedAt >= timing.holdThreshold {
                gestures.append(event.key == .left ? .leftHold : .rightHold)
                return gestures
            }

            if let pendingTap,
               event.timestamp - pendingTap.releasedAt <= timing.sequenceWindow
            {
                if pendingTap.key == event.key {
                    gestures.append(event.key == .left ? .leftDoubleTap : .rightDoubleTap)
                } else {
                    gestures.append(pendingTap.key == .left ? .leftThenRight : .rightThenLeft)
                }
                self.pendingTap = nil
            } else {
                pendingTap = (event.key, event.timestamp)
            }
        }
        return gestures
    }

    public mutating func flush(at timestamp: TimeInterval) -> [HyperdeckGesture] {
        var gestures: [HyperdeckGesture] = []

        if let chordStartedAt,
           !chordWasEmitted,
           timestamp - chordStartedAt >= timing.bothHoldThreshold
        {
            gestures.append(.bothHold)
            chordWasEmitted = true
        } else if chordStartedAt == nil {
            for (key, pressedAt) in downSince
                where !emittedHolds.contains(key) && timestamp - pressedAt >= timing.holdThreshold
            {
                gestures.append(key == .left ? .leftHold : .rightHold)
                emittedHolds.insert(key)
            }
        }

        if downSince.isEmpty,
           let pendingTap,
           timestamp - pendingTap.releasedAt >= timing.sequenceWindow
        {
            gestures.append(pendingTap.key == .left ? .leftTap : .rightTap)
            self.pendingTap = nil
        }
        return gestures
    }

    /// The next monotonic timestamp at which `flush(at:)` can emit a gesture.
    /// Runtime clients can sleep until this deadline instead of polling.
    public var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []

        if let chordStartedAt, !chordWasEmitted {
            deadlines.append(chordStartedAt + timing.bothHoldThreshold)
        } else if chordStartedAt == nil {
            deadlines.append(contentsOf: downSince.compactMap { key, pressedAt in
                emittedHolds.contains(key) ? nil : pressedAt + timing.holdThreshold
            })
        }

        if downSince.isEmpty, let pendingTap {
            deadlines.append(pendingTap.releasedAt + timing.sequenceWindow)
        }
        return deadlines.min()
    }

    public mutating func reset() {
        downSince.removeAll()
        emittedHolds.removeAll()
        chordStartedAt = nil
        chordWasEmitted = false
        pendingTap = nil
    }
}

public struct HyperdeckRGBColor: Codable, Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let purple = Self(red: 124, green: 92, blue: 255)
    public static let blue = Self(red: 0, green: 104, blue: 255)
    public static let green = Self(red: 44, green: 210, blue: 120)
    public static let orange = Self(red: 255, green: 150, blue: 32)
    public static let white = Self(red: 240, green: 244, blue: 255)
}

public enum HyperdeckActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case openApplication
    case openURL
    case runShortcut
    case delay
    case copyText
    case showNotification
    case setRGB
    case runExecutable
    case openCodex
    case acknowledgeCodex
    case nextCodexReview
    case showKeyboardStudio
    case toggleFocus
    case resetFocus
    case clipboardPrevious
    case clipboardNext
    case clipboardCopySelected

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Do nothing"
        case .openApplication: "Open application"
        case .openURL: "Open URL"
        case .runShortcut: "Run macOS Shortcut"
        case .delay: "Wait"
        case .copyText: "Copy text"
        case .showNotification: "Show notification"
        case .setRGB: "Set keyboard RGB"
        case .runExecutable: "Run approved executable"
        case .openCodex: "Open Codex"
        case .acknowledgeCodex: "Acknowledge Codex"
        case .nextCodexReview: "Next Codex review"
        case .showKeyboardStudio: "Show Keyboard Studio"
        case .toggleFocus: "Start or pause focus"
        case .resetFocus: "Reset focus timer"
        case .clipboardPrevious: "Previous clipboard item"
        case .clipboardNext: "Next clipboard item"
        case .clipboardCopySelected: "Copy selected clipboard item"
        }
    }
}

public struct HyperdeckActionStep: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: HyperdeckActionKind
    public var value: String
    public var detail: String
    public var duration: TimeInterval
    public var color: HyperdeckRGBColor
    public var arguments: [String]
    public var passesClipboard: Bool

    public init(
        id: UUID = UUID(),
        kind: HyperdeckActionKind,
        value: String = "",
        detail: String = "",
        duration: TimeInterval = 0,
        color: HyperdeckRGBColor = .purple,
        arguments: [String] = [],
        passesClipboard: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.detail = detail
        self.duration = duration
        self.color = color
        self.arguments = arguments
        self.passesClipboard = passesClipboard
    }
}

public struct HyperdeckRecipe: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var steps: [HyperdeckActionStep]

    public init(id: UUID = UUID(), name: String, symbol: String = "bolt.fill", steps: [HyperdeckActionStep]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.steps = steps
    }
}

public struct HyperdeckProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bundleIdentifiers: [String]
    public var color: HyperdeckRGBColor
    public var assignments: [HyperdeckGesture: UUID]

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifiers: [String] = [],
        color: HyperdeckRGBColor = .purple,
        assignments: [HyperdeckGesture: UUID] = [:]
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.color = color
        self.assignments = assignments
    }
}

public struct HyperdeckConfiguration: Codable, Equatable, Sendable {
    public var format: String
    public var timing: HyperdeckGestureTiming
    public var recipes: [HyperdeckRecipe]
    public var profiles: [HyperdeckProfile]
    public var focusMinutes: Int
    public var clipboardMonitoringEnabled: Bool

    public init(
        timing: HyperdeckGestureTiming = .init(),
        recipes: [HyperdeckRecipe],
        profiles: [HyperdeckProfile],
        focusMinutes: Int = 25,
        clipboardMonitoringEnabled: Bool = false
    ) {
        format = "Keyboard Studio Hyperdeck 1.0"
        self.timing = timing
        self.recipes = recipes
        self.profiles = profiles
        self.focusMinutes = focusMinutes
        self.clipboardMonitoringEnabled = clipboardMonitoringEnabled
    }

    /// Resolves a profile override first, then inherits from the fallback
    /// profile whose bundle identifier list is empty.
    public func recipeID(for gesture: HyperdeckGesture, profileID: UUID?) -> UUID? {
        let profileRecipeID = profiles.first(where: { $0.id == profileID })?.assignments[gesture]
        return profileRecipeID ?? profiles.first(where: { $0.bundleIdentifiers.isEmpty })?.assignments[gesture]
    }

    public static var defaults: Self {
        let openCodexID = UUID(uuidString: "08F43250-3A85-4FE5-A3D1-65EB422A6141")!
        let acknowledgeID = UUID(uuidString: "59C89B3E-04B9-42D7-9058-FC570B97FC40")!
        let nextReviewID = UUID(uuidString: "CB172767-8970-42CC-A3A6-169238881A8B")!
        let toggleFocusID = UUID(uuidString: "CF8D5639-057E-43A6-96CD-E79E05814C5E")!
        let resetFocusID = UUID(uuidString: "7CD85192-7A88-47B9-99C9-EE3358D2E2D3")!
        let clipboardPreviousID = UUID(uuidString: "95F2F1D3-8241-4461-B3A9-92065740210D")!
        let clipboardNextID = UUID(uuidString: "934981E7-C4A8-427F-81AF-69D0FB2B15DB")!
        let clipboardCopyID = UUID(uuidString: "F9D99E80-3EB1-486D-8469-F3C57CBE453F")!
        let showStudioID = UUID(uuidString: "6E34EF61-603D-4B3F-B5F8-37D9AC089DA6")!
        let quickNoteID = UUID(uuidString: "7505F746-D081-434C-86AB-9D6E88144925")!

        let recipes = [
            HyperdeckRecipe(id: openCodexID, name: "Open Codex", symbol: "arrow.up.forward.app.fill", steps: [.init(kind: .openCodex)]),
            HyperdeckRecipe(id: acknowledgeID, name: "Clear Codex alerts", symbol: "checkmark.circle.fill", steps: [.init(kind: .acknowledgeCodex)]),
            HyperdeckRecipe(id: nextReviewID, name: "Next Codex review", symbol: "text.badge.checkmark", steps: [.init(kind: .nextCodexReview)]),
            HyperdeckRecipe(id: toggleFocusID, name: "Start / pause focus", symbol: "timer", steps: [.init(kind: .toggleFocus)]),
            HyperdeckRecipe(id: resetFocusID, name: "Reset focus timer", symbol: "arrow.counterclockwise", steps: [.init(kind: .resetFocus)]),
            HyperdeckRecipe(id: clipboardPreviousID, name: "Previous clipboard item", symbol: "chevron.left", steps: [.init(kind: .clipboardPrevious)]),
            HyperdeckRecipe(id: clipboardNextID, name: "Next clipboard item", symbol: "chevron.right", steps: [.init(kind: .clipboardNext)]),
            HyperdeckRecipe(id: clipboardCopyID, name: "Copy clipboard selection", symbol: "doc.on.clipboard", steps: [.init(kind: .clipboardCopySelected)]),
            HyperdeckRecipe(id: showStudioID, name: "Show Keyboard Studio", symbol: "keyboard.badge.ellipsis", steps: [.init(kind: .showKeyboardStudio)]),
            HyperdeckRecipe(
                id: quickNoteID,
                name: "Run Quick Note Shortcut",
                symbol: "note.text.badge.plus",
                steps: [.init(kind: .runShortcut, value: "Quick Note", passesClipboard: true)]
            ),
        ]

        let standardAssignments: [HyperdeckGesture: UUID] = [
            .leftTap: openCodexID,
            .rightTap: acknowledgeID,
            .leftHold: toggleFocusID,
            .rightHold: clipboardNextID,
            .leftDoubleTap: clipboardPreviousID,
            .rightDoubleTap: clipboardCopyID,
            .bothTap: showStudioID,
            .bothHold: resetFocusID,
            .leftThenRight: nextReviewID,
            .rightThenLeft: quickNoteID,
        ]

        return Self(
            recipes: recipes,
            profiles: [
                HyperdeckProfile(name: "Everywhere", color: .purple, assignments: standardAssignments),
                HyperdeckProfile(
                    name: "Codex",
                    bundleIdentifiers: ["com.openai.codex"],
                    color: .blue,
                    assignments: standardAssignments
                ),
                HyperdeckProfile(name: "Xcode", bundleIdentifiers: ["com.apple.dt.Xcode"], color: .blue),
                HyperdeckProfile(name: "Terminal", bundleIdentifiers: ["com.apple.Terminal", "com.googlecode.iterm2"], color: .green),
                HyperdeckProfile(name: "Browser", bundleIdentifiers: ["com.apple.Safari", "com.google.Chrome"], color: .orange),
                HyperdeckProfile(name: "Finder", bundleIdentifiers: ["com.apple.finder"], color: .white),
            ],
            focusMinutes: 25,
            clipboardMonitoringEnabled: false
        )
    }
}
