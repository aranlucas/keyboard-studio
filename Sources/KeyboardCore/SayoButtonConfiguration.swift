import Foundation

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
