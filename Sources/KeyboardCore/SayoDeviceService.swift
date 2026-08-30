import CHIDBridge
import Foundation
import OSLog

public enum SayoDeviceServiceError: Error, LocalizedError, Sendable {
    case transport(String)
    case keyboardAccessRequired
    case malformedCString

    public var errorDescription: String? {
        switch self {
        case let .transport(message): message
        case .keyboardAccessRequired:
            "Keyboard access is required. Grant Input Monitoring, then quit and reopen Keyboard Studio."
        case .malformedCString: "The HID device returned malformed identity text."
        }
    }
}

public enum SayoKeyboardAccessStatus: Int, Equatable, Sendable {
    case granted = 0
    case denied = 1
    case unknown = 2
}

public struct SayoLightingV2Configuration: Codable, Equatable, Sendable {
    public var number: UInt8
    public var mode: UInt8
    public var values: [UInt8]

    public init(number: UInt8, mode: UInt8, values: [UInt8]) {
        self.number = number
        self.mode = mode
        self.values = values
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

public actor SayoDeviceService {
    private static let logger = Logger(subsystem: "com.lucas.keyboardstudio", category: "SayoHID")
    public static let vendorID: UInt16 = 0x8089
    public static let productID: UInt16 = 0x000C
    public static let usagePage: UInt32 = 0xFF00
    public static let usage: UInt32 = 0x0001

    public init() {}

    public func accessStatus() -> SayoKeyboardAccessStatus {
        SayoKeyboardAccessStatus(rawValue: Int(sayo_hid_access_status())) ?? .unknown
    }

    public func requestAccess() -> Bool {
        sayo_hid_request_access() == 1
    }

    public func isPresent() -> Bool {
        (try? findDevice()) != nil
    }

    public func readSnapshot(buttonCount: Int = 2) throws -> SayoDeviceSnapshot {
        guard accessStatus() == .granted else {
            throw SayoDeviceServiceError.keyboardAccessRequired
        }
        let identity = try findDevice()
        let initResponse = try transact(makeInitPacket())
        guard initResponse.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0, code: initResponse.command)
        }

        let firmwareVersion: UInt16? = initResponse.payload.count >= 2
            ? UInt16(initResponse.payload[0]) << 8 | UInt16(initResponse.payload[1])
            : nil
        let modelCode: UInt16? = initResponse.payload.count >= 4
            ? UInt16(initResponse.payload[2]) << 8 | UInt16(initResponse.payload[3])
            : nil
        let supportedCommands = initResponse.payload.count > 8
            ? Array(initResponse.payload.dropFirst(8))
            : []

        let shouldUseModernMap = supportedCommands.contains(22) || supportedCommands.isEmpty
        var buttons: [SayoButtonConfiguration] = []
        for number in 0 ..< buttonCount {
            if shouldUseModernMap,
               let modern = try? readModernButton(number: number)
            {
                buttons.append(modern)
            } else {
                buttons.append(try readLegacyButton(number: number))
            }
        }

        return SayoDeviceSnapshot(
            product: identity.product,
            manufacturer: identity.manufacturer,
            serialNumber: identity.serialNumber,
            vendorID: identity.vendorID,
            productID: identity.productID,
            locationID: identity.locationID,
            firmwareVersion: firmwareVersion,
            modelCode: modelCode,
            supportedCommands: supportedCommands,
            buttons: buttons
        )
    }

    public func writeAndSave(buttons: [SayoButtonConfiguration]) throws -> [SayoButtonConfiguration] {
        var verified: [SayoButtonConfiguration] = []
        for button in buttons {
            let request = try button.writePacket()
            let response = try transact(request)
            let decoded = button.usesModernKeyMap
                ? try SayoButtonConfiguration.decodeModern(response: response)
                : try SayoButtonConfiguration.decodeLegacy(response: response)
            guard decoded.number == button.number else {
                throw SayoProtocolError.invalidPacket("write verification returned the wrong button number")
            }
            let intendedLayers = Array(button.layers.prefix(button.usesModernKeyMap ? 5 : 1))
            guard decoded.layers == intendedLayers else {
                throw SayoProtocolError.invalidPacket("write verification returned different layer data")
            }
            if button.usesModernKeyMap {
                guard decoded.header.dropFirst(2) == button.header.dropFirst(2) else {
                    throw SayoProtocolError.invalidPacket("write verification changed opaque button metadata")
                }
            }
            verified.append(decoded)
        }

        let saveResponse = try transact(SayoPacket(command: 4, payload: [0x72, 0x96]))
        guard saveResponse.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 4, code: saveResponse.command)
        }
        return verified
    }

    public func setStaticLighting(number: Int, red: UInt8, green: UInt8, blue: UInt8) throws {
        guard let lightingNumber = UInt8(exactly: number) else {
            throw SayoProtocolError.invalidPacket("Lighting v2 number is outside the UInt8 range")
        }
        let current = try readLightingV2(number: lightingNumber)
        let updated = try current.settingStaticColor(red: red, green: green, blue: blue)
        try writeLightingV2(updated)
    }

    public func readLightingV2(number: UInt8) throws -> SayoLightingV2Configuration {
        let response = try transact(SayoPacket(command: 0x10, payload: [0, number]))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x10, code: response.command)
        }
        return try decodeLightingV2(response)
    }

    public func readIndexedRecord(command: UInt8, number: UInt8) throws -> SayoIndexedRecord {
        let response = try transact(SayoPacket(command: command, payload: [0, number]))
        return try SayoIndexedRecord.decode(response: response, requestCommand: command)
    }

    public func readIndexedRecords(command: UInt8, limit: Int = 256) throws -> [SayoIndexedRecord] {
        var records: [SayoIndexedRecord] = []
        for number in 0 ..< min(256, max(0, limit)) {
            do {
                records.append(try readIndexedRecord(command: command, number: UInt8(number)))
            } catch let SayoProtocolError.deviceRejected(_, code) where code != 0 {
                break
            }
        }
        return records
    }

    @discardableResult
    public func writeIndexedRecord(command: UInt8, record: SayoIndexedRecord) throws -> SayoIndexedRecord {
        let response = try transact(record.writePacket(command: command))
        let echoed = try SayoIndexedRecord.decode(response: response, requestCommand: command)
        guard echoed == record else {
            throw SayoProtocolError.invalidPacket("indexed record write response did not echo the requested values")
        }
        return echoed
    }

    public func readDeviceName() throws -> String {
        let response = try transact(SayoPacket(command: 0x08, payload: [0]))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x08, code: response.command)
        }
        let bytes = Array(response.payload.drop { $0 == 0 && response.payload.first == 0 })
        return decodeUTF16CString(bytes)
    }

    @discardableResult
    public func writeDeviceName(_ name: String) throws -> String {
        let units = Array(name.utf16.prefix(15))
        var encoded: [UInt8] = []
        for unit in units {
            encoded.append(UInt8(unit & 0xFF))
            encoded.append(UInt8((unit >> 8) & 0xFF))
        }
        encoded += [UInt8](repeating: 0, count: max(0, 30 - encoded.count))
        let response = try transact(SayoPacket(command: 0x08, payload: [1] + encoded + [0]))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x08, code: response.command)
        }
        return try readDeviceName()
    }

    public func readDeviceIdentityConfiguration() throws -> SayoDeviceIdentityConfiguration {
        let response = try transact(SayoPacket(command: 0xFE))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0xFE, code: response.command)
        }
        guard response.payload.count >= 4 else {
            throw SayoProtocolError.invalidPacket("device identity response is shorter than four bytes")
        }
        return SayoDeviceIdentityConfiguration(
            vendorID: UInt16(response.payload[0]) | UInt16(response.payload[1]) << 8,
            productID: UInt16(response.payload[2]) | UInt16(response.payload[3]) << 8
        )
    }

    public func readNamedSlots(command: UInt8, limit: Int = 64) throws -> [SayoNamedSlot] {
        var slots: [SayoNamedSlot] = []
        for number in 0 ..< min(256, max(0, limit)) {
            let response = try transact(SayoPacket(command: command, payload: [0, UInt8(number)]))
            guard response.command == 0 else { break }
            guard response.payload.count >= 2 else {
                throw SayoProtocolError.invalidPacket("named-slot response is shorter than two bytes")
            }
            let raw = Array(response.payload.dropFirst(2))
            let nameBytes = Array(raw.prefix { $0 != 0 })
            slots.append(SayoNamedSlot(
                number: Int(response.payload[1]),
                name: String(decoding: nameBytes, as: UTF8.self),
                rawName: raw
            ))
        }
        return slots
    }

    @discardableResult
    public func writeNamedSlot(command: UInt8, slot: SayoNamedSlot) throws -> SayoNamedSlot {
        guard let number = UInt8(exactly: slot.number) else {
            throw SayoProtocolError.invalidPacket("named-slot number is outside the UInt8 range")
        }
        let encodedName = Array(slot.name.utf8.prefix(32))
        let padded = encodedName + [UInt8](repeating: 0, count: 32 - encodedName.count)
        let response = try transact(SayoPacket(command: command, payload: [1, number] + padded))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: command, code: response.command)
        }
        guard response.payload.count >= 2 else {
            throw SayoProtocolError.invalidPacket("named-slot write response is shorter than two bytes")
        }
        let raw = Array(response.payload.dropFirst(2))
        return SayoNamedSlot(
            number: Int(response.payload[1]),
            name: String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self),
            rawName: raw
        )
    }

    public func readPasswordSlots(limit: Int = 128) throws -> [SayoNamedSlot] {
        try readNamedSlots(command: 0x0B, limit: limit)
    }

    @discardableResult
    public func writePasswordSlot(_ slot: SayoNamedSlot) throws -> SayoNamedSlot {
        guard let number = UInt8(exactly: slot.number) else {
            throw SayoProtocolError.invalidPacket("password-slot number is outside the UInt8 range")
        }
        let encoded = Array(slot.name.utf8.prefix(57))
        let response = try transact(SayoPacket(command: 0x0B, payload: [1, number] + encoded + [0]))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x0B, code: response.command)
        }
        return try readPasswordSlots(limit: slot.number + 1).last
            .unwrap(or: SayoProtocolError.invalidPacket("password slot did not read back after writing"))
    }

    @discardableResult
    public func writeRawScriptImage(_ image: [UInt8]) throws -> Int {
        guard image.count <= 8192 else {
            throw SayoProtocolError.invalidPacket("script image is larger than 8192 bytes")
        }
        var bytes = image
        if bytes.last != 0xFF { bytes += [0xFF, 0xFF] }
        var address = 0
        while address < bytes.count {
            let count = min(54, bytes.count - address)
            let payload = [UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF)]
                + Array(bytes[address ..< address + count])
            let response = try transact(SayoPacket(command: 0xF0, payload: payload))
            guard response.command == 0 else {
                throw SayoProtocolError.deviceRejected(command: 0xF0, code: response.command)
            }
            address += count
        }
        let readBack = try readRawScriptImage(maximumBytes: max(64, bytes.count + 64))
        guard readBack.starts(with: image) else {
            throw SayoProtocolError.invalidPacket("script image did not verify after writing")
        }
        return image.count
    }

    public func saveToFlash() throws {
        let response = try transact(SayoPacket(command: 4, payload: [0x72, 0x96]))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 4, code: response.command)
        }
    }

    public func readRawScriptImage(maximumBytes: Int = 8192) throws -> [UInt8] {
        var image: [UInt8] = []
        var address = 0
        while address < maximumBytes {
            let response = try transact(SayoPacket(
                command: 0xF0,
                payload: [UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF)]
            ))
            guard response.command == 0 else { break }
            guard !response.payload.isEmpty else { break }
            image.append(contentsOf: response.payload)
            address += response.payload.count
            // A full vendor response carries 60 payload bytes. The firmware's
            // final short chunk is the end marker; do not probe one address
            // past it and turn normal discovery into a rejected command.
            if response.payload.count < 60 { break }
        }
        while image.last == 0 { image.removeLast() }
        return image
    }

    @discardableResult
    public func writeLightingV2(
        _ configuration: SayoLightingV2Configuration
    ) throws -> SayoLightingV2Configuration {
        let payload = [1, configuration.number, configuration.mode] + configuration.values
        let response = try transact(SayoPacket(command: 0x10, payload: payload))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x10, code: response.command)
        }
        let echoed = try decodeLightingV2(response)
        guard echoed == configuration else {
            throw SayoProtocolError.invalidPacket("Lighting v2 write response did not echo the requested values")
        }
        return echoed
    }

    private func readModernButton(number: Int) throws -> SayoButtonConfiguration {
        let response = try transact(SayoPacket(command: 22, payload: [0, UInt8(number)]))
        return try SayoButtonConfiguration.decodeModern(response: response)
    }

    private func readLegacyButton(number: Int) throws -> SayoButtonConfiguration {
        let response = try transact(SayoPacket(command: 6, payload: [0, UInt8(number)]))
        return try SayoButtonConfiguration.decodeLegacy(response: response)
    }

    private func makeInitPacket() -> SayoPacket {
        let components = Calendar.current.dateComponents([.day, .hour, .minute, .second], from: Date())
        return SayoPacket(command: 0, payload: [
            UInt8(components.day ?? 1),
            UInt8(components.hour ?? 0),
            UInt8(components.minute ?? 0),
            UInt8(components.second ?? 0),
        ])
    }

    private func decodeLightingV2(_ response: SayoPacket) throws -> SayoLightingV2Configuration {
        guard response.payload.count >= 3 else {
            throw SayoProtocolError.invalidPacket("Lighting v2 response is shorter than three bytes")
        }
        return SayoLightingV2Configuration(
            number: response.payload[1],
            mode: response.payload[2],
            values: Array(response.payload.dropFirst(3))
        )
    }

    private func decodeUTF16CString(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var index = 0
        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            guard unit != 0 else { break }
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func transact(_ packet: SayoPacket) throws -> SayoPacket {
        let output = try packet.encoded()
        Self.logger.debug(
            "HID TX command=\(Int(packet.command), privacy: .public) payloadLength=\(packet.payload.count, privacy: .public)"
        )
        var input = [UInt8](repeating: 0, count: SayoPacket.reportLength)
        var error = [CChar](repeating: 0, count: 256)
        let length = output.withUnsafeBufferPointer { outputBuffer in
            input.withUnsafeMutableBufferPointer { inputBuffer in
                sayo_hid_transact(
                    Self.vendorID,
                    Self.productID,
                    Self.usagePage,
                    Self.usage,
                    outputBuffer.baseAddress,
                    outputBuffer.count,
                    inputBuffer.baseAddress,
                    inputBuffer.count,
                    1200,
                    &error,
                    error.count
                )
            }
        }
        guard length > 0 else {
            let message = decodeCString(error)
            Self.logger.error(
                "HID transport failed command=\(Int(packet.command), privacy: .public): \(message, privacy: .public)"
            )
            throw SayoDeviceServiceError.transport(message)
        }
        let responseBytes = Array(input.prefix(Int(length)))
        let prefix = responseBytes.prefix(64)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        do {
            let response = try SayoPacket.decode(
                responseBytes,
                checksumValidation: .opaqueFirmwareResponseTrailer
            )
            let trailerIndex = 3 + response.payload.count
            let trailer = trailerIndex < responseBytes.count ? responseBytes[trailerIndex] : 0
            if response.command == 0 {
                Self.logger.debug(
                    "HID RX requestCommand=\(Int(packet.command), privacy: .public) status=0 payloadLength=\(response.payload.count, privacy: .public) trailer=\(Int(trailer), privacy: .public)"
                )
            } else {
                Self.logger.error(
                    "HID command rejected requestCommand=\(Int(packet.command), privacy: .public) status=\(Int(response.command), privacy: .public) payloadLength=\(response.payload.count, privacy: .public) trailer=\(Int(trailer), privacy: .public)"
                )
            }
            return response
        } catch {
            Self.logger.error("Could not decode HID response: \(error.localizedDescription, privacy: .public); raw=\(prefix, privacy: .public)")
            throw error
        }
    }

    private func findDevice() throws -> DeviceIdentity {
        var info = sayo_hid_device_info()
        var error = [CChar](repeating: 0, count: 256)
        let found = sayo_hid_find(
            Self.vendorID,
            Self.productID,
            Self.usagePage,
            Self.usage,
            &info,
            &error,
            error.count
        )
        guard found == 1 else {
            throw SayoDeviceServiceError.transport(decodeCString(error))
        }

        return DeviceIdentity(
            product: string(from: info.product),
            manufacturer: string(from: info.manufacturer),
            serialNumber: string(from: info.serial_number),
            vendorID: info.vendor_id,
            productID: info.product_id,
            locationID: info.location_id
        )
    }

    private func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }

    private func decodeCString(_ bytes: [CChar]) -> String {
        String(
            decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

private struct DeviceIdentity: Sendable {
    let product: String
    let manufacturer: String
    let serialNumber: String
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32
}
