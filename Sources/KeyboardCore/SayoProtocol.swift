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
