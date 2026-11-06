import Foundation

public enum SayoDeviceServiceError: Error, LocalizedError, Sendable {
    case transport(String)
    case keyboardAccessRequired
    case deviceSelectionRequired
    case deviceSelectionChanged
    case configurationRefreshRequired

    public var errorDescription: String? {
        switch self {
        case let .transport(message): message
        case .keyboardAccessRequired:
            "Keyboard access is required. Grant Input Monitoring, then quit and reopen Keyboard Studio."
        case .deviceSelectionRequired:
            "Refresh the keyboard before reading or writing device settings."
        case .deviceSelectionChanged: "The selected keyboard changed. Refresh and review the edits before saving."
        case .configurationRefreshRequired: "Refresh and review the keyboard after the incomplete configuration write."
        }
    }
}

public enum SayoKeyboardAccessStatus: Int, Equatable, Sendable {
    case granted = 0
    case denied = 1
    case unknown = 2
}

public actor SayoDeviceService {
    public static let vendorID: UInt16 = 0x8089
    public static let productID: UInt16 = 0x000C
    public static let usagePage: UInt32 = 0xFF00
    public static let usage: UInt32 = 0x0001

    private var selectedDevice: DeviceIdentity?

    private let transport: any SayoHIDTransport
    private var originalStatusLighting: [SayoLightingV2Configuration] = []
    private var statusFrame: [SayoStatusLight] = []
    private var needsRefreshAfterCommitFailure = false

    public init() { transport = SystemSayoHIDTransport() }

    init(transport: any SayoHIDTransport) { self.transport = transport }

    public func accessStatus() -> SayoKeyboardAccessStatus {
        transport.accessStatus()
    }

    public func requestAccess() -> Bool {
        transport.requestAccess()
    }

    public func isPresent() -> Bool {
        (try? transport.findDevice()) != nil
    }

    /// Drops the device selected by the last successful snapshot refresh.
    /// A later explicit refresh is required to select another physical device.
    public func clearSelection() {
        selectedDevice = nil
        originalStatusLighting = []
        statusFrame = []
    }

    public func readSnapshot(buttonCount: Int = 2) throws -> SayoDeviceSnapshot {
        guard (1 ... 16).contains(buttonCount) else {
            throw SayoProtocolError.invalidPacket("button count must be between one and sixteen")
        }
        guard accessStatus() == .granted else {
            clearSelection()
            throw SayoDeviceServiceError.keyboardAccessRequired
        }
        let identity: DeviceIdentity
        do { identity = try transport.findDevice() } catch {
            clearSelection()
            throw error
        }
        guard !identity.serialNumber.isEmpty else {
            clearSelection()
            throw SayoDeviceServiceError.deviceSelectionRequired
        }
        if selectedDevice == identity {
            // A retry on the same physical device must retain the original
            // lighting if restoration fails, rather than adopt the lamp as its baseline.
            do { try restoreStatusLighting() } catch {
                needsRefreshAfterCommitFailure = true
                throw error
            }
        }
        clearSelection()
        let initResponse = try transact(makeInitPacket(), boundTo: identity)
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
               let modern = try? readModernButton(number: number, boundTo: identity)
            {
                buttons.append(modern)
            } else {
                buttons.append(try readLegacyButton(number: number, boundTo: identity))
            }
        }

        let snapshot = SayoDeviceSnapshot(
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
        selectedDevice = identity
        needsRefreshAfterCommitFailure = false
        return snapshot
    }

    /// One synchronous actor turn owns validation, writes, verification and flash.
    /// There are deliberately no suspension points: status updates and subsequent
    /// commits can run only before or after the complete operation.
    public func commitConfiguration(
        _ plan: SayoConfigurationPlan, expectedDevice: SayoDeviceSnapshot
    ) throws -> SayoConfigurationCommitResult {
        let identity = try requireSelectedDevice()
        guard identity.matches(expectedDevice) else {
            throw SayoDeviceServiceError.deviceSelectionChanged
        }
        return try commitConfiguration(plan)
    }

    private func commitConfiguration(_ plan: SayoConfigurationPlan) throws -> SayoConfigurationCommitResult {
        _ = try requireSelectedDevice()
        guard !needsRefreshAfterCommitFailure else {
            throw SayoDeviceServiceError.configurationRefreshRequired
        }
        try plan.validate()
        var verified = plan
        var verifiedCount = 0
        var phase = SayoConfigurationCommitError.Phase.restoringLighting
        let lamp = statusFrame
        do {
            try restoreStatusLighting()
            phase = .writing
            verified.buttons = []
            for button in plan.buttons {
                verified.buttons.append(try writeButton(button))
                verifiedCount += 1
            }
            verified.lighting = []
            for light in plan.lighting {
                verified.lighting.append(try writeLightingV2(light))
                verifiedCount += 1
            }
            verified.colorTables = []
            for record in plan.colorTables {
                verified.colorTables.append(try writeIndexedRecord(command: 0x11, record: record))
                verifiedCount += 1
            }
            verified.scriptSlots = []
            for slot in plan.scriptSlots {
                let echoed = try writeNamedSlot(command: 0xF1, slot: slot)
                guard echoed.number == slot.number,
                      Array(echoed.rawName.prefix(32)) == SayoSlotFormat.script.encode(slot.name)
                else { throw SayoProtocolError.invalidPacket("script name did not verify after writing") }
                verified.scriptSlots.append(echoed)
                verifiedCount += 1
            }
            if let image = plan.scriptImage {
                _ = try writeRawScriptImage(image)
                verifiedCount += 1
            }
            verified.passwords = []
            for slot in plan.passwords {
                let echoed = try writePasswordSlot(slot)
                let intended = SayoSlotFormat.password.decodedName(slot.name)
                guard echoed.number == slot.number, echoed.name == intended else {
                    throw SayoProtocolError.invalidPacket("password slot did not verify after writing")
                }
                verified.passwords.append(echoed)
                verifiedCount += 1
            }
            verified.strings = []
            for record in plan.strings {
                verified.strings.append(try writeIndexedRecord(command: 0x0C, record: record))
                verifiedCount += 1
            }
            if let name = plan.deviceName {
                let echoed = try writeDeviceName(name)
                let intended = String(decoding: name.utf16.prefix(15).prefix { $0 != 0 }, as: UTF16.self)
                guard echoed == intended else {
                    throw SayoProtocolError.invalidPacket("device name did not verify after writing")
                }
                verified.deviceName = echoed
                verifiedCount += 1
            }
            phase = .flashing
            try flashConfiguration()
        } catch {
            needsRefreshAfterCommitFailure = true
            throw SayoConfigurationCommitError(phase: phase, verifiedRecordCount: verifiedCount,
                                               cause: error.localizedDescription)
        }
        // Do not turn a successful flash into an apparent failed save when only
        // the temporary lamp could not be restored.
        do {
            try applyStatusFrame(lamp)
            return SayoConfigurationCommitResult(verified: verified, statusLampWarning: nil)
        } catch {
            return SayoConfigurationCommitResult(verified: verified, statusLampWarning: error.localizedDescription)
        }
    }

    /// Compatibility for the probe; application saves use the expected-device interface.
    public func writeAndSave(buttons: [SayoButtonConfiguration]) throws -> [SayoButtonConfiguration] {
        _ = try requireSelectedDevice()
        guard !buttons.isEmpty else {
            throw SayoProtocolError.invalidPacket("button count must be between one and sixteen")
        }
        return try commitConfiguration(SayoConfigurationPlan(buttons: buttons)).verified.buttons
    }

    public func saveToFlash() throws {
        _ = try commitConfiguration(SayoConfigurationPlan())
    }

    /// Empty frames restore configured lighting. Frames are always volatile;
    /// every flash path suspends them until flash has been acknowledged.
    public func setStatusFrame(_ frame: [SayoStatusLight], expectedDevice: SayoDeviceSnapshot) throws {
        let identity = try requireSelectedDevice()
        guard identity.matches(expectedDevice) else {
            throw SayoDeviceServiceError.deviceSelectionChanged
        }
        guard !needsRefreshAfterCommitFailure else {
            throw SayoDeviceServiceError.configurationRefreshRequired
        }
        guard Set(frame.map(\.number)).count == frame.count else {
            throw SayoProtocolError.invalidPacket("status frame contains duplicate light numbers")
        }
        try restoreStatusLighting()
        try applyStatusFrame(frame)
    }

    private func restoreStatusLighting() throws {
        for light in originalStatusLighting { try writeLightingV2(light) }
        originalStatusLighting = []
    }

    private func applyStatusFrame(_ frame: [SayoStatusLight]) throws {
        let originals = try frame.map { try readLightingV2(number: $0.number) }
        let updated = try zip(originals, frame).map { light, color in
            try light.settingStaticColor(red: color.red, green: color.green, blue: color.blue)
        }
        originalStatusLighting = originals
        statusFrame = frame
        for light in updated { try writeLightingV2(light) }
    }

    private func writeButton(_ button: SayoButtonConfiguration) throws -> SayoButtonConfiguration {
        _ = try requireSelectedDevice()
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
        return decoded
    }

    public func readLightingV2(number: UInt8) throws -> SayoLightingV2Configuration {
        let response = try transact(SayoPacket(command: 0x10, payload: [0, number]))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x10, code: response.command)
        }
        let decoded = try SayoLightingV2Configuration.decode(response)
        guard decoded.number == number else {
            throw SayoProtocolError.invalidPacket("Lighting v2 read returned the wrong light number")
        }
        return decoded
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
        _ = try requireSelectedDevice()
        guard record.values.count <= 57 else {
            throw SayoProtocolError.invalidPacket("indexed record has more than 57 value bytes")
        }
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
        let bytes = Array(response.payload.dropFirst())
        return decodeUTF16CString(bytes)
    }

    @discardableResult
    public func writeDeviceName(_ name: String) throws -> String {
        _ = try requireSelectedDevice()
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
        _ = try requireSelectedDevice()
        guard let number = UInt8(exactly: slot.number) else {
            throw SayoProtocolError.invalidPacket("named-slot number is outside the UInt8 range")
        }
        let padded = SayoSlotFormat.script.encode(slot.name)
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
        _ = try requireSelectedDevice()
        guard let number = UInt8(exactly: slot.number) else {
            throw SayoProtocolError.invalidPacket("password-slot number is outside the UInt8 range")
        }
        let encoded = SayoSlotFormat.password.encode(slot.name)
        let response = try transact(SayoPacket(command: 0x0B, payload: [1, number] + encoded))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x0B, code: response.command)
        }
        return try readPasswordSlots(limit: slot.number + 1).last
            .unwrap(or: SayoProtocolError.invalidPacket("password slot did not read back after writing"))
    }

    @discardableResult
    public func writeRawScriptImage(_ image: [UInt8]) throws -> Int {
        _ = try requireSelectedDevice()
        guard image.count <= SayoDeviceBackup.maximumScriptImageBytes else {
            throw SayoProtocolError.invalidPacket("script image is larger than \(SayoDeviceBackup.maximumScriptImageBytes) bytes")
        }
        var bytes = image
        if bytes.last != 0xFF {
            guard bytes.count + 2 <= SayoDeviceBackup.maximumScriptImageBytes else {
                throw SayoProtocolError.invalidPacket("script image leaves no room for the required terminator")
            }
            bytes += [0xFF, 0xFF]
        }
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
        guard readBack.starts(with: bytes) else {
            throw SayoProtocolError.invalidPacket("script image did not verify after writing")
        }
        return image.count
    }

    private func flashConfiguration() throws {
        _ = try requireSelectedDevice()
        let response = try transact(SayoPacket(command: 4, payload: [0x72, 0x96]))
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 4, code: response.command)
        }
    }

    public func readRawScriptImage(maximumBytes: Int = 8192) throws -> [UInt8] {
        guard maximumBytes >= 0 else {
            throw SayoProtocolError.invalidPacket("script image limit cannot be negative")
        }
        let boundedMaximum = min(maximumBytes, SayoDeviceBackup.maximumScriptImageBytes)
        var image: [UInt8] = []
        var address = 0
        while address < boundedMaximum {
            let response = try transact(SayoPacket(
                command: 0xF0,
                payload: [UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF)]
            ))
            guard response.command == 0 else { break }
            guard !response.payload.isEmpty else { break }
            let chunk = Array(response.payload.prefix(boundedMaximum - address))
            image.append(contentsOf: chunk)
            address += chunk.count
            // A full vendor response carries 60 payload bytes. The firmware's
            // final short chunk is the end marker; do not probe one address
            // past it and turn normal discovery into a rejected command.
            if response.payload.count < 60 || chunk.count < response.payload.count { break }
        }
        while image.last == 0 { image.removeLast() }
        return image
    }

    @discardableResult
    public func writeLightingV2(
        _ configuration: SayoLightingV2Configuration
    ) throws -> SayoLightingV2Configuration {
        _ = try requireSelectedDevice()
        let response = try transact(configuration.writePacket())
        guard response.command == 0 else {
            throw SayoProtocolError.deviceRejected(command: 0x10, code: response.command)
        }
        let echoed = try SayoLightingV2Configuration.decode(response)
        guard echoed == configuration else {
            throw SayoProtocolError.invalidPacket("Lighting v2 write response did not echo the requested values")
        }
        return echoed
    }

    private func readModernButton(number: Int, boundTo identity: DeviceIdentity? = nil) throws -> SayoButtonConfiguration {
        let response = try transact(SayoPacket(command: 22, payload: [0, UInt8(number)]), boundTo: identity)
        return try SayoButtonConfiguration.decodeModern(response: response)
    }

    private func readLegacyButton(number: Int, boundTo identity: DeviceIdentity? = nil) throws -> SayoButtonConfiguration {
        let response = try transact(SayoPacket(command: 6, payload: [0, UInt8(number)]), boundTo: identity)
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

    private func transact(_ packet: SayoPacket, boundTo identity: DeviceIdentity? = nil) throws -> SayoPacket {
        try transport.transact(packet, boundTo: requireSelectedDevice(identity))
    }

    private func requireSelectedDevice(_ identity: DeviceIdentity? = nil) throws -> DeviceIdentity {
        let target = identity ?? selectedDevice
        guard let target, !target.serialNumber.isEmpty else {
            throw SayoDeviceServiceError.deviceSelectionRequired
        }
        return target
    }


}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
