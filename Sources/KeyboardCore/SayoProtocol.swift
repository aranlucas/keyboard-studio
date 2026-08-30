import Foundation

public enum SayoProtocolError: Error, LocalizedError, Equatable {
    case invalidPacket(String)
    case invalidBackup(String)
    case deviceRejected(command: UInt8, code: UInt8)
    case unsupportedConfiguration

    public var errorDescription: String? {
        switch self {
        case let .invalidPacket(reason):
            "Invalid SayoDevice packet: \(reason)"
        case let .invalidBackup(reason):
            "Invalid Keyboard Studio backup: \(reason)"
        case let .deviceRejected(command, code):
            "The keyboard rejected command \(command) with code \(code)."
        case .unsupportedConfiguration:
            "This firmware does not expose a supported button-mapping command."
        }
    }
}

public struct SayoPacket: Equatable, Sendable {
    public static let reportID: UInt8 = 0x02
    public static let reportLength = 64

    public var command: UInt8
    public var payload: [UInt8]

    public init(command: UInt8, payload: [UInt8] = []) {
        self.command = command
        self.payload = payload
    }

    public func encoded() throws -> [UInt8] {
        guard payload.count <= 60 else {
            throw SayoProtocolError.invalidPacket("payload is longer than 60 bytes")
        }

        var bytes = [UInt8](repeating: 0, count: Self.reportLength)
        bytes[0] = Self.reportID
        bytes[1] = command
        bytes[2] = UInt8(payload.count)
        bytes.replaceSubrange(3 ..< 3 + payload.count, with: payload)
        bytes[3 + payload.count] = bytes.prefix(3 + payload.count).reduce(0, &+)
        return bytes
    }

    public enum ChecksumValidation: Equatable, Sendable {
        case required
        case opaqueFirmwareResponseTrailer
    }

    public static func decode(
        _ bytes: [UInt8],
        checksumValidation: ChecksumValidation = .required
    ) throws -> SayoPacket {
        guard bytes.count >= 4 else {
            throw SayoProtocolError.invalidPacket("report is shorter than four bytes")
        }
        guard bytes[0] == reportID else {
            throw SayoProtocolError.invalidPacket("unexpected report ID 0x\(String(bytes[0], radix: 16))")
        }

        let payloadLength = Int(bytes[2])
        guard payloadLength <= 60, bytes.count > 3 + payloadLength else {
            throw SayoProtocolError.invalidPacket("declared payload length is out of bounds")
        }

        let expected = bytes.prefix(3 + payloadLength).reduce(0, &+)
        guard checksumValidation == .opaqueFirmwareResponseTrailer
            || bytes[3 + payloadLength] == expected
        else {
            throw SayoProtocolError.invalidPacket("checksum mismatch")
        }
        return SayoPacket(command: bytes[1], payload: Array(bytes[3 ..< 3 + payloadLength]))
    }
}

public struct SayoKeyLayer: Equatable, Codable, Sendable, Identifiable {
    public var id: Int
    public var mode: UInt8
    public var reserved: UInt8
    public var modifier: UInt8
    public var keyCodes: [UInt8]

    public init(
        id: Int,
        mode: UInt8 = 0,
        reserved: UInt8 = 0,
        modifier: UInt8 = 0,
        keyCodes: [UInt8] = [0, 0, 0]
    ) {
        self.id = id
        self.mode = mode
        self.reserved = reserved
        self.modifier = modifier
        self.keyCodes = Array((keyCodes + [0, 0, 0]).prefix(3))
    }

    public var bytes: [UInt8] {
        [mode, reserved, modifier] + Array((keyCodes + [0, 0, 0]).prefix(3))
    }
}

public struct SayoButtonConfiguration: Equatable, Codable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var header: [UInt8]
    public var layers: [SayoKeyLayer]
    public var usesModernKeyMap: Bool

    public init(number: Int, header: [UInt8], layers: [SayoKeyLayer], usesModernKeyMap: Bool) {
        self.number = number
        self.header = header
        self.layers = layers
        self.usesModernKeyMap = usesModernKeyMap
    }

    public static func decodeModern(response: SayoPacket) throws -> SayoButtonConfiguration {
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 22, code: response.command)
        }
        guard response.payload.count >= 22 else {
            throw SayoProtocolError.invalidPacket("key-map response is too short")
        }

        let header = Array(response.payload.prefix(16))
        let number = Int(header[1])
        let layerCount = min(5, (response.payload.count - 16) / 6)
        let layers = (0 ..< layerCount).map { layerIndex in
            let offset = 16 + layerIndex * 6
            return SayoKeyLayer(
                id: layerIndex,
                mode: response.payload[offset],
                reserved: response.payload[offset + 1],
                modifier: response.payload[offset + 2],
                keyCodes: Array(response.payload[(offset + 3) ... (offset + 5)])
            )
        }
        return SayoButtonConfiguration(number: number, header: header, layers: layers, usesModernKeyMap: true)
    }

    public static func decodeLegacy(response: SayoPacket) throws -> SayoButtonConfiguration {
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 6, code: response.command)
        }
        guard response.payload.count >= 8 else {
            throw SayoProtocolError.invalidPacket("legacy button response is too short")
        }

        return SayoButtonConfiguration(
            number: Int(response.payload[1]),
            header: Array(response.payload.prefix(4)),
            layers: [
                SayoKeyLayer(
                    id: 0,
                    mode: response.payload[2],
                    modifier: response.payload[4],
                    keyCodes: Array(response.payload[5 ... 7])
                ),
            ],
            usesModernKeyMap: false
        )
    }

    public func writePacket() throws -> SayoPacket {
        guard !layers.isEmpty else {
            throw SayoProtocolError.invalidPacket("button has no layers")
        }
        guard let encodedNumber = UInt8(exactly: number) else {
            throw SayoProtocolError.invalidPacket("button number is outside the UInt8 range")
        }
        let maximumLayerCount = usesModernKeyMap ? 5 : 1
        guard layers.count <= maximumLayerCount else {
            throw SayoProtocolError.invalidPacket("button has more than \(maximumLayerCount) layers")
        }
        let maximumHeaderLength = usesModernKeyMap ? 16 : 4
        guard header.count <= maximumHeaderLength else {
            throw SayoProtocolError.invalidPacket("button header is too long")
        }
        guard layers.allSatisfy({ $0.keyCodes.count <= 3 }) else {
            throw SayoProtocolError.invalidPacket("button layer has more than three key codes")
        }

        if usesModernKeyMap {
            var mutableHeader = Array((header + [UInt8](repeating: 0, count: 16)).prefix(16))
            mutableHeader[0] = 1
            mutableHeader[1] = encodedNumber
            return SayoPacket(command: 22, payload: mutableHeader + layers.prefix(5).flatMap(\.bytes))
        }

        let layer = layers[0]
        return SayoPacket(
            command: 6,
            payload: [1, encodedNumber, layer.mode, 0, layer.modifier] + layer.keyCodes
        )
    }
}

public struct SayoDeviceSnapshot: Equatable, Codable, Sendable {
    public var product: String
    public var manufacturer: String
    public var serialNumber: String
    public var vendorID: UInt16
    public var productID: UInt16
    public var locationID: UInt32
    public var firmwareVersion: UInt16?
    public var modelCode: UInt16?
    public var supportedCommands: [UInt8]
    public var buttons: [SayoButtonConfiguration]

    public init(
        product: String,
        manufacturer: String,
        serialNumber: String,
        vendorID: UInt16,
        productID: UInt16,
        locationID: UInt32,
        firmwareVersion: UInt16? = nil,
        modelCode: UInt16? = nil,
        supportedCommands: [UInt8] = [],
        buttons: [SayoButtonConfiguration] = []
    ) {
        self.product = product
        self.manufacturer = manufacturer
        self.serialNumber = serialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.firmwareVersion = firmwareVersion
        self.modelCode = modelCode
        self.supportedCommands = supportedCommands
        self.buttons = buttons
    }
}

public struct SayoIndexedRecord: Equatable, Codable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var mode: UInt8
    public var values: [UInt8]

    public init(number: Int, mode: UInt8, values: [UInt8]) {
        self.number = number
        self.mode = mode
        self.values = values
    }

    public static func decode(response: SayoPacket, requestCommand: UInt8) throws -> Self {
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: requestCommand, code: response.command)
        }
        guard response.payload.count >= 3 else {
            throw SayoProtocolError.invalidPacket("indexed record response is shorter than three bytes")
        }
        return Self(
            number: Int(response.payload[1]),
            mode: response.payload[2],
            values: Array(response.payload.dropFirst(3))
        )
    }

    public func writePacket(command: UInt8) throws -> SayoPacket {
        guard let encodedNumber = UInt8(exactly: number) else {
            throw SayoProtocolError.invalidPacket("indexed record number is outside the UInt8 range")
        }
        guard values.count <= 57 else {
            throw SayoProtocolError.invalidPacket("indexed record has more than 57 value bytes")
        }
        return SayoPacket(command: command, payload: [1, encodedNumber, mode] + values)
    }
}

public struct SayoNamedSlot: Equatable, Codable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var name: String
    public var rawName: [UInt8]

    public init(number: Int, name: String, rawName: [UInt8]) {
        self.number = number
        self.name = name
        self.rawName = rawName
    }
}

public struct SayoDeviceIdentityConfiguration: Equatable, Codable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16

    public init(vendorID: UInt16, productID: UInt16) {
        self.vendorID = vendorID
        self.productID = productID
    }
}

public struct SayoDeviceBackup: Equatable, Codable, Sendable {
    public static let formatIdentifier = "Keyboard Studio SayoDevice Backup 1.0"
    public static let maximumScriptImageBytes = 8192

    public var format: String
    public var createdAt: Date
    public var product: String
    public var serialNumber: String
    public var modelCode: UInt16?
    public var firmwareVersion: UInt16?
    public var buttons: [SayoButtonConfiguration]
    public var lighting: [SayoLightingV2Configuration]
    public var colorTables: [SayoIndexedRecord]
    public var scriptNames: [SayoNamedSlot]
    public var scriptImage: [UInt8]
    public var deviceName: String
    public var passwords: [SayoNamedSlot]?
    public var strings: [SayoIndexedRecord]

    public init(
        createdAt: Date = Date(),
        product: String,
        serialNumber: String,
        modelCode: UInt16?,
        firmwareVersion: UInt16?,
        buttons: [SayoButtonConfiguration],
        lighting: [SayoLightingV2Configuration],
        colorTables: [SayoIndexedRecord],
        scriptNames: [SayoNamedSlot],
        scriptImage: [UInt8],
        deviceName: String,
        passwords: [SayoNamedSlot]? = nil,
        strings: [SayoIndexedRecord] = []
    ) {
        format = Self.formatIdentifier
        self.createdAt = createdAt
        self.product = product
        self.serialNumber = serialNumber
        self.modelCode = modelCode
        self.firmwareVersion = firmwareVersion
        self.buttons = buttons
        self.lighting = lighting
        self.colorTables = colorTables
        self.scriptNames = scriptNames
        self.scriptImage = scriptImage
        self.deviceName = deviceName
        self.passwords = passwords
        self.strings = strings
    }

    public func validate(for snapshot: SayoDeviceSnapshot) throws {
        guard format == Self.formatIdentifier else {
            throw SayoProtocolError.invalidBackup("unrecognized backup format")
        }
        guard product == snapshot.product else {
            throw SayoProtocolError.invalidBackup("backup product does not match the connected keyboard")
        }
        guard serialNumber == snapshot.serialNumber else {
            throw SayoProtocolError.invalidBackup("backup serial number does not match the connected keyboard")
        }
        guard modelCode == snapshot.modelCode else {
            throw SayoProtocolError.invalidBackup("backup model does not match the connected keyboard")
        }
        guard buttons.count == snapshot.buttons.count else {
            throw SayoProtocolError.invalidBackup("backup button count does not match the connected keyboard")
        }

        for (index, button) in buttons.enumerated() {
            let current = snapshot.buttons[index]
            guard button.number == current.number,
                  button.usesModernKeyMap == current.usesModernKeyMap,
                  button.layers.count == current.layers.count,
                  button.header.count == current.header.count,
                  button.layers.allSatisfy({ $0.keyCodes.count <= 3 })
            else {
                throw SayoProtocolError.invalidBackup("button \(index + 1) shape does not match the connected keyboard")
            }
            _ = try button.writePacket()
            for (layer, currentLayer) in zip(button.layers, current.layers) {
                guard layer.id == currentLayer.id,
                      layer.keyCodes.count == currentLayer.keyCodes.count
                else {
                    throw SayoProtocolError.invalidBackup("button \(index + 1) contains an invalid layer shape")
                }
            }
        }

        let supportedCommands = Set(snapshot.supportedCommands)
        try validateLighting(supportedCommands: supportedCommands)
        try validateIndexedRecords(
            colorTables,
            name: "color table",
            command: 0x11,
            supportedCommands: supportedCommands,
            expectedCount: supportedCommands.contains(0x11) ? 6 : 0
        )
        try validateNamedSlots(
            scriptNames,
            name: "script",
            command: 0xF1,
            supportedCommands: supportedCommands,
            expectedCount: supportedCommands.contains(0xF1) ? 2 : 0,
            maximumNameBytes: 32,
            maximumSlots: 64
        )
        guard scriptImage.count <= Self.maximumScriptImageBytes else {
            throw SayoProtocolError.invalidBackup("script image is larger than \(Self.maximumScriptImageBytes) bytes")
        }
        guard scriptImage.isEmpty || supportedCommands.contains(0xF0) else {
            throw SayoProtocolError.invalidBackup("backup contains script bytecode unsupported by this keyboard")
        }
        try validateNamedSlots(
            passwords ?? [],
            name: "password",
            command: 0x0B,
            supportedCommands: supportedCommands,
            expectedCount: nil,
            maximumNameBytes: 57,
            maximumSlots: 128
        )
        if passwords != nil, !supportedCommands.contains(0x0B) {
            throw SayoProtocolError.invalidBackup("backup contains password slots unsupported by this keyboard")
        }
        try validateIndexedRecords(
            strings,
            name: "text",
            command: 0x0C,
            supportedCommands: supportedCommands,
            expectedCount: supportedCommands.contains(0x0C) ? 16 : 0
        )
        guard deviceName.utf16.count <= 15 else {
            throw SayoProtocolError.invalidBackup("device name is longer than 15 UTF-16 code units")
        }
        guard deviceName.isEmpty || supportedCommands.contains(0x08) else {
            throw SayoProtocolError.invalidBackup("backup contains a device name unsupported by this keyboard")
        }
    }

    private func validateLighting(supportedCommands: Set<UInt8>) throws {
        let expectedCount = supportedCommands.contains(0x10) ? 2 : 0
        guard lighting.count == expectedCount else {
            throw SayoProtocolError.invalidBackup("lighting record count does not match keyboard capabilities")
        }
        for (index, record) in lighting.enumerated() {
            guard record.number == index, (9 ... 57).contains(record.values.count) else {
                throw SayoProtocolError.invalidBackup("lighting record \(index + 1) has an invalid shape")
            }
        }
    }

    private func validateIndexedRecords(
        _ records: [SayoIndexedRecord],
        name: String,
        command: UInt8,
        supportedCommands: Set<UInt8>,
        expectedCount: Int
    ) throws {
        guard records.count == expectedCount else {
            throw SayoProtocolError.invalidBackup("\(name) record count does not match keyboard capabilities")
        }
        guard records.allSatisfy({ $0.values.count <= 57 }) else {
            throw SayoProtocolError.invalidBackup("a \(name) record is too large")
        }
        guard records.enumerated().allSatisfy({ $0.element.number == $0.offset }) else {
            throw SayoProtocolError.invalidBackup("\(name) record numbers are not sequential")
        }
        if !records.isEmpty, !supportedCommands.contains(command) {
            throw SayoProtocolError.invalidBackup("backup contains \(name) records unsupported by this keyboard")
        }
    }

    private func validateNamedSlots(
        _ slots: [SayoNamedSlot],
        name: String,
        command: UInt8,
        supportedCommands: Set<UInt8>,
        expectedCount: Int?,
        maximumNameBytes: Int,
        maximumSlots: Int
    ) throws {
        if let expectedCount, slots.count != expectedCount {
            throw SayoProtocolError.invalidBackup("\(name) slot count does not match keyboard capabilities")
        }
        guard slots.count <= maximumSlots else {
            throw SayoProtocolError.invalidBackup("too many \(name) slots")
        }
        guard slots.enumerated().allSatisfy({ index, slot in
            slot.number == index
                && slot.name.utf8.count <= maximumNameBytes
                && slot.rawName.count <= maximumNameBytes + (name == "password" ? 1 : 0)
        }) else {
            throw SayoProtocolError.invalidBackup("a \(name) slot has an invalid shape")
        }
        if !slots.isEmpty, !supportedCommands.contains(command) {
            throw SayoProtocolError.invalidBackup("backup contains \(name) slots unsupported by this keyboard")
        }
    }
}

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

public enum CodexDeckProfile {
    public static let openCodexHIDKey: UInt8 = 0x68 // F13
    public static let acknowledgeHIDKey: UInt8 = 0x6B // F16
    public static let openCodexVirtualKey: UInt16 = 105
    public static let acknowledgeVirtualKey: UInt16 = 106
    public static let layerIndex = 0

    public static func applying(
        to buttons: [SayoButtonConfiguration],
        layerIndex: Int = layerIndex
    ) throws -> [SayoButtonConfiguration] {
        guard buttons.count >= 2,
              layerIndex >= 0,
              buttons[0].layers.indices.contains(layerIndex),
              buttons[1].layers.indices.contains(layerIndex)
        else {
            throw SayoProtocolError.unsupportedConfiguration
        }

        var updated = buttons
        let keyCodes = [openCodexHIDKey, acknowledgeHIDKey]
        for buttonIndex in 0 ..< 2 {
            let existing = updated[buttonIndex].layers[layerIndex]
            updated[buttonIndex].layers[layerIndex] = SayoKeyLayer(
                id: existing.id,
                mode: 0,
                reserved: existing.reserved,
                modifier: 0,
                keyCodes: [keyCodes[buttonIndex], 0, 0]
            )
        }
        return updated
    }

    public static func isInstalled(
        in buttons: [SayoButtonConfiguration],
        layerIndex: Int = layerIndex
    ) -> Bool {
        guard buttons.count >= 2,
              layerIndex >= 0,
              buttons[0].layers.indices.contains(layerIndex),
              buttons[1].layers.indices.contains(layerIndex)
        else { return false }

        let first = buttons[0].layers[layerIndex]
        let second = buttons[1].layers[layerIndex]
        return first.mode == 0
            && first.modifier == 0
            && first.keyCodes == [openCodexHIDKey, 0, 0]
            && second.mode == 0
            && second.modifier == 0
            && second.keyCodes == [acknowledgeHIDKey, 0, 0]
    }

    public static func action(forVirtualKeyCode keyCode: UInt16) -> CodexDeckAction? {
        switch keyCode {
        case openCodexVirtualKey: .openCodex
        case acknowledgeVirtualKey: .acknowledge
        default: nil
        }
    }
}

public enum CodexDeckAction: Sendable {
    case openCodex
    case acknowledge
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
