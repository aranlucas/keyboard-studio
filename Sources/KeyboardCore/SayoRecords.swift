import Foundation

public struct SayoLightingV2Configuration: Codable, Equatable, Sendable {
    public var number: UInt8
    public var mode: UInt8
    public var values: [UInt8]

    public init(number: UInt8, mode: UInt8, values: [UInt8]) {
        self.number = number
        self.mode = mode
        self.values = values
    }

    func writePacket() -> SayoPacket {
        SayoPacket(command: 0x10, payload: [1, number, mode] + values)
    }

    static func decode(_ response: SayoPacket) throws -> Self {
        guard response.payload.count >= 3 else {
            throw SayoProtocolError.invalidPacket("Lighting v2 response is shorter than three bytes")
        }
        return Self(number: response.payload[1], mode: response.payload[2], values: Array(response.payload.dropFirst(3)))
    }

    public func settingStaticColor(red: UInt8, green: UInt8, blue: UInt8) throws -> Self {
        guard values.count >= 9 else {
            throw SayoProtocolError.invalidPacket("Lighting v2 record has fewer than nine value bytes")
        }
        var updatedValues = values
        updatedValues.replaceSubrange(0 ..< 9, with: [0, 0, 0, red, green, blue, 0, 0, 0])
        return Self(number: number, mode: 0, values: updatedValues)
    }

    public var effect: SayoLightingEffect? {
        get { SayoLightingEffect(rawValue: mode) }
        set { if let newValue { mode = newValue.rawValue } }
    }

    public var colorSource: UInt8 {
        get { values.indices.contains(0) ? values[0] : 0 }
        set { if values.indices.contains(0) { values[0] = newValue } }
    }

    public var speed: UInt8 {
        get { values.indices.contains(1) ? values[1] : 0 }
        set { if values.indices.contains(1) { values[1] = newValue } }
    }

    public var event: UInt8 {
        get { values.indices.contains(2) ? values[2] : 0 }
        set { if values.indices.contains(2) { values[2] = newValue } }
    }

    public var red: UInt8 {
        get { values.indices.contains(3) ? values[3] : 0 }
        set { if values.indices.contains(3) { values[3] = newValue } }
    }

    public var green: UInt8 {
        get { values.indices.contains(4) ? values[4] : 0 }
        set { if values.indices.contains(4) { values[4] = newValue } }
    }

    public var blue: UInt8 {
        get { values.indices.contains(5) ? values[5] : 0 }
        set { if values.indices.contains(5) { values[5] = newValue } }
    }

    public var onTime: UInt8 {
        get { values.indices.contains(6) ? values[6] : 0 }
        set { if values.indices.contains(6) { values[6] = newValue } }
    }

    public var offTime: UInt8 {
        get { values.indices.contains(7) ? values[7] : 0 }
        set { if values.indices.contains(7) { values[7] = newValue } }
    }

    public var colorTable: UInt8 {
        get { values.indices.contains(8) ? values[8] : 0 }
        set { if values.indices.contains(8) { values[8] = newValue } }
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

    /// Firmware text records store UTF-8 bytes in pairs; bytes after the first
    /// 56 belong to the firmware and must survive text edits.
    public var textValue: String {
        get {
            var bytes: [UInt8] = []
            var index = 0
            while index + 1 < min(56, values.count) {
                if values[index] == 0, values[index + 1] != 0 {
                    bytes.append(values[index + 1])
                } else if values[index] != 0 || values[index + 1] != 0 {
                    bytes.append(values[index])
                    bytes.append(values[index + 1])
                } else { break }
                index += 2
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        set {
            let bytes = Array(newValue.utf8.prefix(28))
            let encoded = bytes.flatMap { [UInt8(0), $0] }
            let tail = Array(values.dropFirst(56))
            values = encoded + [UInt8](repeating: 0, count: 56 - encoded.count) + tail
        }
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

// Observed O2L V2 banks: discovery must not probe unsupported indices.
public enum SayoO2LRecordBounds {
    public static let lighting = 2
    public static let colorTables = 6
    public static let scriptNames = 2
    public static let strings = 16
}

enum SayoSlotFormat {
    case script, password

    var maximumNameBytes: Int { self == .script ? 32 : 57 }
    var maximumRawNameBytes: Int { self == .script ? 32 : 58 }

    func encode(_ name: String) -> [UInt8] {
        let bytes = Array(name.utf8.prefix(maximumNameBytes))
        switch self {
        case .script: return bytes + [UInt8](repeating: 0, count: maximumNameBytes - bytes.count)
        case .password: return bytes + [0]
        }
    }

    func decodedName(_ name: String) -> String {
        String(decoding: encode(name).prefix { $0 != 0 }, as: UTF8.self)
    }
}
