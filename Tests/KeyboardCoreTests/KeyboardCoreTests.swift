import Foundation
import KeyboardCore
import Testing

private func thrownSayoError(_ operation: () throws -> Any) -> SayoProtocolError? {
    do {
        _ = try operation()
        return nil
    } catch {
        return error as? SayoProtocolError
    }
}

private func serviceThrowsDeviceSelectionRequired(_ operation: () async throws -> Any) async -> Bool {
    do {
        _ = try await operation()
        return false
    } catch {
        guard let error = error as? SayoDeviceServiceError else { return false }
        if case .deviceSelectionRequired = error { return true }
        return false
    }
}

struct SayoPacketTests {
    @Test
    func encodeDecodeRoundTripUsesAdditiveChecksum() throws {
        let packet = SayoPacket(command: 0x04, payload: [0x72, 0x96])

        let encoded = try packet.encoded()

        #expect(encoded.count == SayoPacket.reportLength)
        #expect(Array(encoded.prefix(6)) == [0x02, 0x04, 0x02, 0x72, 0x96, 0x10])
        let decoded = try SayoPacket.decode(encoded)
        #expect(decoded == packet)
    }

    @Test
    func decodeRejectsInvalidChecksumAndPayloadBounds() throws {
        var corrupt = try SayoPacket(command: 0, payload: [1, 2, 3]).encoded()
        corrupt[6] ^= 0xFF

        #expect(thrownSayoError { try SayoPacket.decode(corrupt) } == .invalidPacket("checksum mismatch"))

        let truncated = [SayoPacket.reportID, 0, 3, 1]
        #expect(
            thrownSayoError { try SayoPacket.decode(truncated) }
                == .invalidPacket("declared payload length is out of bounds")
        )

        let oversized = [SayoPacket.reportID, 0, 61] + [UInt8](repeating: 0, count: 61)
        #expect(
            thrownSayoError { try SayoPacket.decode(oversized) }
                == .invalidPacket("declared payload length is out of bounds")
        )

        #expect(
            thrownSayoError {
                try SayoPacket(command: 0, payload: [UInt8](repeating: 0, count: 61)).encoded()
            } == .invalidPacket("payload is longer than 60 bytes")
        )
    }

    @Test
    func opaqueFirmwareTrailerCanBeDecodedOnlyWhenOptedIn() throws {
        let packet = SayoPacket(command: 0, payload: [0x08, 0x9A])
        var encoded = try packet.encoded()
        encoded[5] = 0x23

        #expect(thrownSayoError { try SayoPacket.decode(encoded) } == .invalidPacket("checksum mismatch"))
        let decoded = try SayoPacket.decode(encoded, checksumValidation: .opaqueFirmwareResponseTrailer)
        #expect(decoded == packet)
    }

    @Test
    func buttonWriteRejectsNumbersOutsideTheWireRange() {
        let layer = SayoKeyLayer(id: 0, keyCodes: [0x04, 0, 0])
        let negative = SayoButtonConfiguration(
            number: -1,
            header: [UInt8](repeating: 0, count: 16),
            layers: [layer],
            usesModernKeyMap: true
        )
        let oversized = SayoButtonConfiguration(
            number: 256,
            header: [UInt8](repeating: 0, count: 16),
            layers: [layer],
            usesModernKeyMap: true
        )

        #expect(
            thrownSayoError { try negative.writePacket() }
                == .invalidPacket("button number is outside the UInt8 range")
        )
        #expect(
            thrownSayoError { try oversized.writePacket() }
                == .invalidPacket("button number is outside the UInt8 range")
        )
    }

    @Test
    func indexedRecordWriteRejectsValuesOutsideTheWireRange() {
        let oversized = SayoIndexedRecord(number: 0, mode: 0, values: [UInt8](repeating: 0, count: 58))

        #expect(
            thrownSayoError { try oversized.writePacket(command: 0x0C) }
                == .invalidPacket("indexed record has more than 57 value bytes")
        )
    }
}

struct SayoBackupValidationTests {
    private let buttons = [
        SayoButtonConfiguration(
            number: 0,
            header: [UInt8](repeating: 0, count: 16),
            layers: [SayoKeyLayer(id: 0, keyCodes: [0x04, 0, 0])],
            usesModernKeyMap: true
        ),
        SayoButtonConfiguration(
            number: 1,
            header: [UInt8](repeating: 0, count: 16),
            layers: [SayoKeyLayer(id: 0, keyCodes: [0x05, 0, 0])],
            usesModernKeyMap: true
        ),
    ]

    private var snapshot: SayoDeviceSnapshot {
        SayoDeviceSnapshot(
            product: "SayoDevice O2L V2",
            manufacturer: "SayoDevice",
            serialNumber: "test-device",
            vendorID: SayoDeviceService.vendorID,
            productID: SayoDeviceService.productID,
            locationID: 0,
            firmwareVersion: 1,
            modelCode: 2,
            supportedCommands: [],
            buttons: buttons
        )
    }

    private var backup: SayoDeviceBackup {
        SayoDeviceBackup(
            product: "SayoDevice O2L V2",
            serialNumber: "test-device",
            modelCode: 2,
            firmwareVersion: 1,
            buttons: buttons,
            lighting: [],
            colorTables: [],
            scriptNames: [],
            scriptImage: [],
            deviceName: "",
            strings: []
        )
    }

    @Test
    func matchingBackupPassesIdentityAndCapabilityValidation() throws {
        try backup.validate(for: snapshot)
    }

    @Test
    func backupRejectsDataForUnsupportedCommands() {
        var invalid = backup
        invalid.scriptImage = [0x11, 0x04, 0xFF]

        #expect(
            thrownSayoError { try invalid.validate(for: snapshot) }
                == .invalidBackup("backup contains script bytecode unsupported by this keyboard")
        )
    }

    @Test
    func backupRejectsDifferentPhysicalDevice() {
        var invalid = backup
        invalid.serialNumber = "another-device"

        #expect(
            thrownSayoError { try invalid.validate(for: snapshot) }
                == .invalidBackup("backup serial number does not match the connected keyboard")
        )
    }

    @Test
    func backupRejectsDifferentFirmware() {
        var invalid = backup
        invalid.firmwareVersion = 2

        #expect(
            thrownSayoError { try invalid.validate(for: snapshot) }
                == .invalidBackup("backup firmware does not match the connected keyboard")
        )
    }
}

struct SayoDeviceSelectionTests {
    @Test
    func destructiveWritesRequireAnExplicitSnapshotSelection() async {
        let service = SayoDeviceService()

        #expect(
            await serviceThrowsDeviceSelectionRequired { try await service.saveToFlash() }
        )
    }
}

struct HyperdeckGestureRecognizerTests {
    private let timing = HyperdeckGestureTiming(
        chordWindow: 0.25,
        sequenceWindow: 0.5,
        holdThreshold: 0.75,
        bothHoldThreshold: 1.5
    )

    private func event(
        _ key: HyperdeckKey,
        _ phase: HyperdeckKeyPhase,
        at timestamp: TimeInterval
    ) -> HyperdeckPhysicalEvent {
        HyperdeckPhysicalEvent(key: key, phase: phase, timestamp: timestamp)
    }

    @Test
    func singleHoldFlushesOnlyAtItsDeadline() {
        var recognizer = HyperdeckGestureRecognizer(timing: timing)

        #expect(recognizer.handle(event(.left, .down, at: 0)).isEmpty)
        #expect(abs((recognizer.nextDeadline ?? -1) - timing.holdThreshold) < 0.000_001)
        #expect(recognizer.flush(at: timing.holdThreshold - 0.001).isEmpty)
        #expect(recognizer.flush(at: timing.holdThreshold) == [.leftHold])
        #expect(recognizer.nextDeadline == nil)
        #expect(recognizer.handle(event(.left, .up, at: 1)).isEmpty)
    }

    @Test
    func deferredTapFlushesAtInclusiveSequenceBoundary() {
        var recognizer = HyperdeckGestureRecognizer(timing: timing)

        #expect(recognizer.handle(event(.left, .down, at: 2)).isEmpty)
        #expect(recognizer.handle(event(.left, .up, at: 2.1)).isEmpty)
        #expect(abs((recognizer.nextDeadline ?? -1) - 2.6) < 0.000_001)
        #expect(recognizer.flush(at: 2.599).isEmpty)
        #expect(recognizer.flush(at: 2.6) == [.leftTap])
        #expect(recognizer.nextDeadline == nil)
    }

    @Test
    func bothHoldFlushesAtItsDeadlineWithoutDuplicateOnRelease() {
        var recognizer = HyperdeckGestureRecognizer(timing: timing)

        #expect(recognizer.handle(event(.left, .down, at: 4)).isEmpty)
        #expect(recognizer.handle(event(.right, .down, at: 4.25)).isEmpty)
        #expect(abs((recognizer.nextDeadline ?? -1) - 5.5) < 0.000_001)
        #expect(recognizer.flush(at: 5.499).isEmpty)
        #expect(recognizer.flush(at: 5.5) == [.bothHold])
        #expect(recognizer.nextDeadline == nil)
        #expect(recognizer.handle(event(.left, .up, at: 5.6)).isEmpty)
        #expect(recognizer.handle(event(.right, .up, at: 5.7)).isEmpty)
    }

    @Test
    func chordWindowIsInclusiveAndOutsideEventsBecomeAnOrderedSequence() {
        var boundary = HyperdeckGestureRecognizer(timing: timing)
        #expect(boundary.handle(event(.left, .down, at: 0)).isEmpty)
        #expect(boundary.handle(event(.right, .down, at: timing.chordWindow)).isEmpty)
        #expect(boundary.handle(event(.left, .up, at: 0.35)).isEmpty)
        #expect(boundary.handle(event(.right, .up, at: 0.4)) == [.bothTap])

        var outside = HyperdeckGestureRecognizer(timing: timing)
        #expect(outside.handle(event(.left, .down, at: 1)).isEmpty)
        #expect(outside.handle(event(.right, .down, at: 1.251)).isEmpty)
        #expect(outside.handle(event(.left, .up, at: 1.35)).isEmpty)
        #expect(outside.handle(event(.right, .up, at: 1.4)) == [.leftThenRight])
    }
}
