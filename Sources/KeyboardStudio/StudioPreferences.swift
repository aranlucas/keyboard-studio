import Foundation

enum StudioPreferences {
    static let activityRefreshIntervalKey = "activityRefreshInterval"
    static let defaultActivityRefreshInterval = 15.0
    static let minimumActivityRefreshInterval = 5.0
    static let maximumActivityRefreshInterval = 60.0
    static let statusLampEnabledKey = "codexStatusLampEnabled"
    static let defaultStatusLampEnabled = true
    static let selectedSectionKey = "selectedStudioSection"
}

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

