import Foundation

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
        guard firmwareVersion == snapshot.firmwareVersion else {
            throw SayoProtocolError.invalidBackup("backup firmware does not match the connected keyboard")
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
            expectedCount: supportedCommands.contains(0x11) ? SayoO2LRecordBounds.colorTables : 0
        )
        try validateNamedSlots(
            scriptNames,
            name: "script",
            command: 0xF1,
            supportedCommands: supportedCommands,
            expectedCount: supportedCommands.contains(0xF1) ? SayoO2LRecordBounds.scriptNames : 0,
            format: .script,
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
            format: .password,
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
            expectedCount: supportedCommands.contains(0x0C) ? SayoO2LRecordBounds.strings : 0
        )
        guard deviceName.utf16.count <= 15 else {
            throw SayoProtocolError.invalidBackup("device name is longer than 15 UTF-16 code units")
        }
        guard deviceName.isEmpty || supportedCommands.contains(0x08) else {
            throw SayoProtocolError.invalidBackup("backup contains a device name unsupported by this keyboard")
        }
    }

    private func validateLighting(supportedCommands: Set<UInt8>) throws {
        let expectedCount = supportedCommands.contains(0x10) ? SayoO2LRecordBounds.lighting : 0
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
        format: SayoSlotFormat,
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
                && slot.name.utf8.count <= format.maximumNameBytes
                && slot.rawName.count <= format.maximumRawNameBytes
        }) else {
            throw SayoProtocolError.invalidBackup("a \(name) slot has an invalid shape")
        }
        if !slots.isEmpty, !supportedCommands.contains(command) {
            throw SayoProtocolError.invalidBackup("backup contains \(name) slots unsupported by this keyboard")
        }
    }
}
