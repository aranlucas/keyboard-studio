import Foundation

public enum SayoScriptTemplate {
    public static func tapKey(_ key: UInt8, pressMilliseconds: UInt8 = 35) -> [UInt8] {
        [0x11, key, 0x06, pressMilliseconds, 0x19, key, 0xFF]
    }

    public static func repeatWhileHeld(_ key: UInt8, intervalMilliseconds: UInt8 = 35) -> [UInt8] {
        [
            0xF8,
            0x11, key,
            0x06, intervalMilliseconds,
            0x19, key,
            0x06, intervalMilliseconds,
            0xFB,
            0xFE,
            0xFF,
        ]
    }

    public static func setSelectedLED(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        [0xE1, red, green, blue, 0xFF]
    }
}

public enum SayoLightingEffect: UInt8, CaseIterable, Codable, Identifiable, Sendable {
    case staticColor = 0
    case indicator = 1
    case breathing = 2
    case breathingOnce = 3
    case gradient = 4
    case switchColor = 6
    case switchOnce = 7
    case blinking = 8
    case blinkOnce = 9
    case fadeOut = 14
    case fadeIn = 15

    public var id: UInt8 { rawValue }

    public var title: String {
        switch self {
        case .staticColor: "Static"
        case .indicator: "Lock indicator"
        case .breathing: "Breathing"
        case .breathingOnce: "Breathe once"
        case .gradient: "Gradient"
        case .switchColor: "Color switch"
        case .switchOnce: "Switch once"
        case .blinking: "Blinking"
        case .blinkOnce: "Blink once"
        case .fadeOut: "Fade out"
        case .fadeIn: "Fade in"
        }
    }
}

public enum SayoKeyModeCatalog {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: UInt8 { code }
        public let code: UInt8
        public let title: String
        public let detail: String

        public init(_ code: UInt8, _ title: String, _ detail: String) {
            self.code = code
            self.title = title
            self.detail = detail
        }
    }

    public static let entries: [Entry] = [
        Entry(0, "Basic key", "Modifier plus up to three keyboard keys"),
        Entry(1, "Keyboard chord", "Modifier plus up to three simultaneous keys"),
        Entry(2, "Mouse", "Mouse buttons, horizontal, vertical, and scroll movement"),
        Entry(3, "Media control", "Volume, playback, browser, and system media commands"),
        Entry(5, "Non-interrupting key", "Basic key action that is not interrupted by another key"),
        Entry(8, "One-key password", "Types a password slot with optional Return and interval"),
        Entry(9, "Repeat A", "Repeated key with randomized delay"),
        Entry(10, "Repeat AB", "Alternating two-key repeat"),
        Entry(11, "Repeat ABC", "Three-key repeat"),
        Entry(12, "Repeat ABABC", "Five-step repeating pattern"),
        Entry(13, "Repeat A until any key", "Repeats until another key is pressed"),
        Entry(14, "Repeat AB until any key", "Alternates until another key is pressed"),
        Entry(15, "Repeat ABC until any key", "Repeats until another key is pressed"),
        Entry(16, "Repeat ABABC until any key", "Pattern repeats until another key is pressed"),
        Entry(17, "Delayed key", "Keyboard action with a fixed millisecond delay"),
        Entry(18, "Random-delay key", "Keyboard action with fixed plus random delay"),
        Entry(19, "Random-delay repeat", "Repeating key with fixed plus random delay"),
        Entry(20, "Repeat ABBBB until any key", "Custom repeat pattern"),
        Entry(21, "Sequence ABC", "Sends three keys in sequence, then stops"),
        Entry(22, "Timed repeat AB", "Alternating keys with a configured interval"),
        Entry(23, "Repeat ABCCCC until any key", "Custom repeat pattern"),
        Entry(25, "Repeat A while held", "Stops when the physical key is released"),
        Entry(26, "Repeat AB while held", "Stops when the physical key is released"),
        Entry(27, "Repeat ABC while held", "Stops when the physical key is released"),
        Entry(28, "Repeat ABABC while held", "Stops when the physical key is released"),
        Entry(32, "Random key", "Chooses from configured keyboard values"),
        Entry(33, "Two-step key", "First action on press, second action on release"),
        Entry(40, "Gamepad button", "USB game-controller button"),
        Entry(48, "One-key text", "Types a stored text slot"),
        Entry(49, "Encoder media", "Direction plus media control"),
        Entry(62, "Script · momentary", "Runs a custom script once"),
        Entry(63, "Script · toggle", "Runs until the key is pressed again"),
        Entry(128, "Momentary layer", "Switches layer while held"),
        Entry(129, "Toggle layer", "Switches layer until changed again"),
    ] + (0 ..< 32).map { Entry(UInt8(64 + $0), "Script \($0 + 1)", "Runs named script slot \($0 + 1)") }

    public static func entry(for code: UInt8) -> Entry {
        entries.first(where: { $0.code == code })
            ?? Entry(code, String(format: "Mode 0x%02X", code), "Firmware-defined mode; raw parameters are preserved")
    }
}

public enum SayoMediaCatalog {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: UInt8 { code }
        public let name: String
        public let code: UInt8
    }

    public static let entries: [Entry] = [
        Entry(name: "None", code: 0),
        Entry(name: "Brightness Up", code: 1), Entry(name: "Brightness Down", code: 2),
        Entry(name: "Camera Toggle", code: 3), Entry(name: "Screen Recording", code: 4),
        Entry(name: "Game Bar", code: 5), Entry(name: "Screenshot", code: 6),
        Entry(name: "Broadcast", code: 7), Entry(name: "Mute", code: 8),
        Entry(name: "Volume Up", code: 10), Entry(name: "Volume Down", code: 11),
        Entry(name: "Play / Pause", code: 12), Entry(name: "Stop", code: 13),
        Entry(name: "Previous Track", code: 14), Entry(name: "Next Track", code: 15),
        Entry(name: "Media Select", code: 20), Entry(name: "Mail", code: 21),
        Entry(name: "Calculator", code: 22), Entry(name: "Computer", code: 23),
        Entry(name: "Web Search", code: 24), Entry(name: "Web Home", code: 25),
        Entry(name: "Web Back", code: 26), Entry(name: "Web Forward", code: 27),
        Entry(name: "Web Stop", code: 28), Entry(name: "Web Refresh", code: 29),
        Entry(name: "Web Favorites", code: 30),
    ]
}

public enum HIDKeyCatalog {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: UInt8 { code }
        public let name: String
        public let code: UInt8

        public init(_ name: String, _ code: UInt8) {
            self.name = name
            self.code = code
        }
    }

    public static let entries: [Entry] = {
        var values = [Entry("None", 0)]
        values += zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ", UInt8(0x04) ... UInt8(0x1D)).map {
            Entry(String($0.0), $0.1)
        }
        values += [
            Entry("1", 0x1E), Entry("2", 0x1F), Entry("3", 0x20), Entry("4", 0x21),
            Entry("5", 0x22), Entry("6", 0x23), Entry("7", 0x24), Entry("8", 0x25),
            Entry("9", 0x26), Entry("0", 0x27), Entry("Return", 0x28), Entry("Escape", 0x29),
            Entry("Delete", 0x2A), Entry("Tab", 0x2B), Entry("Space", 0x2C),
            Entry("Right Arrow", 0x4F), Entry("Left Arrow", 0x50),
            Entry("Down Arrow", 0x51), Entry("Up Arrow", 0x52),
        ]
        values += (1 ... 12).map { Entry("F\($0)", UInt8(0x39 + $0)) }
        values += (13 ... 24).map { Entry("F\($0)", UInt8(0x5B + $0)) }
        return values
    }()

    public static func name(for code: UInt8) -> String {
        entries.first(where: { $0.code == code })?.name ?? String(format: "0x%02X", code)
    }
}

public enum HIDModifier: UInt8, CaseIterable, Identifiable, Sendable {
    case control = 0x01
    case shift = 0x02
    case option = 0x04
    case command = 0x08

    public var id: UInt8 { rawValue }

    public var title: String {
        switch self {
        case .control: "Control"
        case .shift: "Shift"
        case .option: "Option"
        case .command: "Command"
        }
    }
}
