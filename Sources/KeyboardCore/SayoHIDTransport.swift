import Foundation

// The actor owns ordering; adapters perform synchronous, identity-bound I/O.
// Synchronous operations intentionally cannot suspend a configuration commit.
protocol SayoHIDTransport: Sendable {
    func accessStatus() -> SayoKeyboardAccessStatus
    func requestAccess() -> Bool
    func findDevice() throws -> DeviceIdentity
    func transact(_ packet: SayoPacket, boundTo identity: DeviceIdentity) throws -> SayoPacket
}

struct DeviceIdentity: Equatable, Sendable {
    let product: String
    let manufacturer: String
    let serialNumber: String
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32

    func matches(_ snapshot: SayoDeviceSnapshot) -> Bool {
        serialNumber == snapshot.serialNumber && vendorID == snapshot.vendorID
            && productID == snapshot.productID && locationID == snapshot.locationID
    }
}

#if os(macOS)
import CHIDBridge
import OSLog

struct SystemSayoHIDTransport: SayoHIDTransport {
    private static let logger = Logger(subsystem: "com.lucas.keyboardstudio", category: "SayoHID")

    func accessStatus() -> SayoKeyboardAccessStatus {
        SayoKeyboardAccessStatus(rawValue: Int(sayo_hid_access_status())) ?? .unknown
    }

    func requestAccess() -> Bool { sayo_hid_request_access() == 1 }

    func transact(_ packet: SayoPacket, boundTo target: DeviceIdentity) throws -> SayoPacket {
        let output = try packet.encoded()
        Self.logger.debug(
            "HID TX command=\(Int(packet.command), privacy: .public) payloadLength=\(packet.payload.count, privacy: .public)"
        )
        var input = [UInt8](repeating: 0, count: SayoPacket.reportLength)
        var error = [CChar](repeating: 0, count: 256)
        let length = target.serialNumber.withCString { serialNumber in
            output.withUnsafeBufferPointer { outputBuffer in
                input.withUnsafeMutableBufferPointer { inputBuffer in
                    sayo_hid_transact(
                        SayoDeviceService.vendorID,
                        SayoDeviceService.productID,
                        SayoDeviceService.usagePage,
                        SayoDeviceService.usage,
                        serialNumber,
                        target.locationID,
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
        }
        guard length > 0 else {
            let message = decodeCString(error)
            Self.logger.error(
                "HID transport failed command=\(Int(packet.command), privacy: .public): \(message, privacy: .private)"
            )
            throw SayoDeviceServiceError.transport(message)
        }
        let responseBytes = Array(input.prefix(Int(length)))
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
            Self.logger.error("Could not decode HID response: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func findDevice() throws -> DeviceIdentity {
        var info = sayo_hid_device_info()
        var error = [CChar](repeating: 0, count: 256)
        let found = sayo_hid_find(
            SayoDeviceService.vendorID,
            SayoDeviceService.productID,
            SayoDeviceService.usagePage,
            SayoDeviceService.usage,
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
#else
// Linux supports offline protocol and scripted-transport tests only.
struct SystemSayoHIDTransport: SayoHIDTransport {
    func accessStatus() -> SayoKeyboardAccessStatus { .denied }
    func requestAccess() -> Bool { false }
    func findDevice() throws -> DeviceIdentity {
        throw SayoDeviceServiceError.transport("Live HID access requires macOS.")
    }
    func transact(_ packet: SayoPacket, boundTo identity: DeviceIdentity) throws -> SayoPacket {
        throw SayoDeviceServiceError.transport("Live HID access requires macOS.")
    }
}
#endif
