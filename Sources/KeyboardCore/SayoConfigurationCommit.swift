import Foundation

/// An immutable-at-call-time snapshot of the edits to persist together.
public struct SayoConfigurationPlan: Equatable, Sendable {
    public var buttons: [SayoButtonConfiguration]
    public var lighting: [SayoLightingV2Configuration]
    public var colorTables: [SayoIndexedRecord]
    public var scriptSlots: [SayoNamedSlot]
    public var scriptImage: [UInt8]?
    public var passwords: [SayoNamedSlot]
    public var strings: [SayoIndexedRecord]
    public var deviceName: String?

    public init(
        buttons: [SayoButtonConfiguration] = [], lighting: [SayoLightingV2Configuration] = [],
        colorTables: [SayoIndexedRecord] = [], scriptSlots: [SayoNamedSlot] = [],
        scriptImage: [UInt8]? = nil, passwords: [SayoNamedSlot] = [],
        strings: [SayoIndexedRecord] = [], deviceName: String? = nil
    ) {
        self.buttons = buttons
        self.lighting = lighting
        self.colorTables = colorTables
        self.scriptSlots = scriptSlots
        self.scriptImage = scriptImage
        self.passwords = passwords
        self.strings = strings
        self.deviceName = deviceName
    }

    // Validate every record before even restoring the transient lamp.
    func validate() throws {
        guard buttons.count <= 16 else {
            throw SayoProtocolError.invalidPacket("button count must not exceed sixteen")
        }
        try unique(buttons.map(\.number))
        for button in buttons { _ = try button.writePacket().encoded() }
        try unique(lighting.map { Int($0.number) })
        for light in lighting {
            guard (9 ... 57).contains(light.values.count) else {
                throw SayoProtocolError.invalidPacket("Lighting v2 record must contain nine to 57 value bytes")
            }
            _ = try SayoPacket(command: 0x10, payload: [1, light.number, light.mode] + light.values).encoded()
        }
        for (command, records) in [(UInt8(0x11), colorTables), (UInt8(0x0C), strings)] {
            try unique(records.map(\.number))
            for record in records { _ = try record.writePacket(command: command).encoded() }
        }
        for slots in [scriptSlots, passwords] {
            try unique(slots.map(\.number))
            guard slots.allSatisfy({ UInt8(exactly: $0.number) != nil }) else {
                throw SayoProtocolError.invalidPacket("named-slot number is outside the UInt8 range")
            }
        }
        if let scriptImage {
            let requiredBytes = scriptImage.count + (scriptImage.last == 0xFF ? 0 : 2)
            guard requiredBytes <= SayoDeviceBackup.maximumScriptImageBytes else {
                throw SayoProtocolError.invalidPacket("script image leaves no room for the required terminator")
            }
        }
    }

    private func unique(_ numbers: [Int]) throws {
        guard Set(numbers).count == numbers.count else {
            throw SayoProtocolError.invalidPacket("configuration contains duplicate record numbers")
        }
    }
}

public struct SayoStatusLight: Equatable, Sendable {
    public let number: UInt8
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(number: UInt8, red: UInt8, green: UInt8, blue: UInt8) {
        self.number = number
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct SayoConfigurationCommitResult: Sendable {
    public let verified: SayoConfigurationPlan
    /// Flash succeeded, but reapplying the volatile status lamp did not.
    public let statusLampWarning: String?
}

public struct SayoConfigurationCommitError: Error, LocalizedError, Sendable {
    public enum Phase: String, Sendable { case restoringLighting, writing, flashing }
    public let phase: Phase
    public let verifiedRecordCount: Int
    public let cause: String
    /// A failed transport acknowledgement cannot establish whether flash changed.
    public var flashMayHaveOccurred: Bool { phase == .flashing }
    public var errorDescription: String? {
        let flash = flashMayHaveOccurred
            ? "Flash was attempted but not confirmed."
            : "No flash command was sent."
        return "Configuration failed during \(phase.rawValue) after \(verifiedRecordCount) verified records. "
            + "Volatile settings may have changed; no rollback is claimed. \(flash) Refresh and review before saving again. \(cause)"
    }
}
