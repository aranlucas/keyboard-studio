import Darwin
import Foundation
import KeyboardCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

do {
    let saveBytes = try SayoPacket(command: 4, payload: [0x72, 0x96]).encoded()
    try check(saveBytes.count == 64, "encoded reports must be 64 bytes")
    try check(Array(saveBytes.prefix(6)) == [0x02, 0x04, 0x02, 0x72, 0x96, 0x10], "save packet checksum differs from the recovered protocol")

    let roundTrip = SayoPacket(command: 0, payload: [0, 1, 0, 2])
    let roundTripBytes = try roundTrip.encoded()
    let roundTripDecoded = try SayoPacket.decode(roundTripBytes)
    try check(roundTripDecoded == roundTrip, "packet round trip failed")

    var corrupt = try SayoPacket(command: 0, payload: [1, 2, 3]).encoded()
    corrupt[6] ^= 0xFF
    do {
        _ = try SayoPacket.decode(corrupt)
        throw CheckFailure.failed("corrupt checksum was accepted")
    } catch is SayoProtocolError {
        // Expected.
    }

    let observedFirmwareResponse: [UInt8] = [
        0x02, 0x00, 0x15, 0x08, 0x9A, 0x00, 0x02, 0xF0,
        0x32, 0xF0, 0x00, 0x04, 0x06, 0x08, 0x0B, 0x0C,
        0x10, 0x11, 0x16, 0xF0, 0xF1, 0xFC, 0xFE, 0xFF,
        0x23,
    ] + [UInt8](repeating: 0, count: 39)
    do {
        _ = try SayoPacket.decode(observedFirmwareResponse)
        throw CheckFailure.failed("strict decoding accepted the firmware's opaque response trailer")
    } catch is SayoProtocolError {
        // Expected: firmware 0x089A returns 0x23, not the outbound additive checksum 0x07.
    }
    let observedInit = try SayoPacket.decode(
        observedFirmwareResponse,
        checksumValidation: .opaqueFirmwareResponseTrailer
    )
    try check(observedInit.command == 0, "observed init response did not decode as success")
    try check(observedInit.payload.prefix(4) == [0x08, 0x9A, 0x00, 0x02], "observed firmware identity decoded incorrectly")

    let observedButtonResponse: [UInt8] = [
        0x02, 0x00, 0x1C, 0x00, 0x00, 0x01, 0x00, 0xDC,
        0x05, 0x66, 0x08, 0x00, 0x00, 0x08, 0x07, 0x08,
        0x07, 0x64, 0x00, 0x00, 0x00, 0x01, 0x06, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x1D, 0x00, 0x00, 0x18,
    ] + [UInt8](repeating: 0, count: 32)
    let observedButtonPacket = try SayoPacket.decode(
        observedButtonResponse,
        checksumValidation: .opaqueFirmwareResponseTrailer
    )
    let observedButton = try SayoButtonConfiguration.decodeModern(response: observedButtonPacket)
    try check(observedButton.number == 0, "observed button response decoded the wrong button number")
    try check(observedButton.layers.count == 2, "observed button response decoded the wrong layer count")
    try check(observedButton.layers[0].mode == 0, "observed keyboard mapping decoded the wrong mode")
    try check(observedButton.layers[0].modifier == 1, "observed Control modifier decoded incorrectly")
    try check(observedButton.layers[0].keyCodes == [0x06, 0, 0], "observed C mapping decoded incorrectly")

    let header: [UInt8] = [0, 1, 0, 0] + [UInt8](repeating: 0, count: 12)
    let layers: [UInt8] = (0 ..< 5).flatMap { layer -> [UInt8] in
        [1, 0, UInt8(layer), UInt8(0x04 + layer), 0, 0]
    }
    let decoded = try SayoButtonConfiguration.decodeModern(
        response: SayoPacket(command: 0, payload: header + layers)
    )
    try check(decoded.number == 1, "modern key map returned the wrong button")
    try check(decoded.layers.count == 5, "modern key map did not preserve five layers")
    try check(decoded.layers[4].modifier == 4, "layer modifier was decoded incorrectly")
    try check(decoded.layers[4].keyCodes[0] == 0x08, "layer key code was decoded incorrectly")

    let button = SayoButtonConfiguration(
        number: 1,
        header: [0, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 4, 5, 6, 7],
        layers: [SayoKeyLayer(id: 0, modifier: 8, keyCodes: [0x06, 0, 0])],
        usesModernKeyMap: true
    )
    let writePacket = try button.writePacket()
    try check(writePacket.command == 22, "modern configuration used the wrong command")
    try check(writePacket.payload[0] == 1, "modern configuration did not set write mode")
    try check(writePacket.payload[2 ... 15] == button.header[2 ... 15], "modern configuration did not preserve opaque header bytes")
    try check(Array(writePacket.payload.suffix(6)) == [0, 0, 8, 0x06, 0, 0], "modern layer did not encode correctly")

    let originalButtons = [
        SayoButtonConfiguration(
            number: 0,
            header: [0, 0] + [UInt8](repeating: 0xA0, count: 14),
            layers: (0 ..< 5).map { SayoKeyLayer(id: $0, reserved: 7, keyCodes: [0x04, 0, 0]) },
            usesModernKeyMap: true
        ),
        SayoButtonConfiguration(
            number: 1,
            header: [0, 1] + [UInt8](repeating: 0xB0, count: 14),
            layers: (0 ..< 5).map { SayoKeyLayer(id: $0, reserved: 8, keyCodes: [0x05, 0, 0]) },
            usesModernKeyMap: true
        ),
    ]
    let deckButtons = try CodexDeckProfile.applying(to: originalButtons)
    try check(deckButtons[0].layers[0].keyCodes == [0x68, 0, 0], "Codex Deck did not map Button 1 to F13")
    try check(deckButtons[1].layers[0].keyCodes == [0x6B, 0, 0], "Codex Deck did not map Button 2 to F16")
    try check(deckButtons[0].layers[0].modifier == 0 && deckButtons[1].layers[0].modifier == 0, "Codex Deck left an unexpected modifier")
    try check(deckButtons[0].layers[1] == originalButtons[0].layers[1], "Codex Deck changed a layer outside Layer 1")
    try check(deckButtons.map(\.header) == originalButtons.map(\.header), "Codex Deck changed opaque button headers")
    try check(CodexDeckProfile.isInstalled(in: deckButtons), "Codex Deck installation was not detected")
    try check(CodexDeckProfile.action(forVirtualKeyCode: 105) == .openCodex, "F13 did not resolve to Open Codex")
    try check(CodexDeckProfile.action(forVirtualKeyCode: 106) == .acknowledge, "F16 did not resolve to Acknowledge")
    try check(CodexDeckProfile.action(forVirtualKeyCode: 107) == nil, "an unrelated function key resolved to a Codex Deck action")

    let originalLighting = SayoLightingV2Configuration(
        number: 1,
        mode: 4,
        values: [16, 64, 2, 0, 0, 0, 100, 100, 3, 9, 8, 7, 6]
    )
    let staticLighting = try originalLighting.settingStaticColor(red: 124, green: 92, blue: 255)
    try check(staticLighting.number == 1 && staticLighting.mode == 0, "Lighting v2 static conversion changed the record identity")
    try check(staticLighting.values.prefix(9) == [0, 0, 0, 124, 92, 255, 0, 0, 0], "Lighting v2 encoded the wrong static fields")
    try check(staticLighting.values.suffix(4) == [9, 8, 7, 6], "Lighting v2 did not preserve opaque trailing values")

    let indexedResponse = SayoPacket(command: 0, payload: [0, 5, 10, 0xAA, 0xBB, 0xCC])
    let indexed = try SayoIndexedRecord.decode(response: indexedResponse, requestCommand: 0x11)
    try check(indexed.number == 5 && indexed.mode == 10, "indexed record identity decoded incorrectly")
    try check(indexed.values == [0xAA, 0xBB, 0xCC], "indexed record values decoded incorrectly")
    let indexedWrite = try indexed.writePacket(command: 0x11)
    try check(indexedWrite.payload == [1, 5, 10, 0xAA, 0xBB, 0xCC], "indexed record write did not preserve values")

    try check(SayoLightingEffect.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 6, 7, 8, 9, 14, 15], "lighting effect catalog differs from the official mode set")
    for mode: UInt8 in [0, 2, 3, 8, 48, 64, 128, 129] {
        try check(SayoKeyModeCatalog.entry(for: mode).code == mode, "key mode \(mode) is missing from the catalog")
    }
    try check(SayoMediaCatalog.entries.contains(where: { $0.code == 12 && $0.name == "Play / Pause" }), "media catalog is missing Play / Pause")

    let tapScript = SayoScriptTemplate.tapKey(0x04, pressMilliseconds: 35)
    try check(tapScript == [0x11, 0x04, 0x06, 35, 0x19, 0x04, 0xFF], "tap-key script template differs from the recovered bytecode")
    let repeatScript = SayoScriptTemplate.repeatWhileHeld(0x05, intervalMilliseconds: 40)
    try check(repeatScript.prefix(2) == [0xF8, 0x11], "repeat script does not start its loop correctly")
    try check(repeatScript.suffix(3) == [0xFB, 0xFE, 0xFF], "repeat script does not close and terminate correctly")

    let backup = SayoDeviceBackup(
        createdAt: Date(timeIntervalSince1970: 1_788_055_260),
        product: "SayoDevice O2L V2",
        serialNumber: "test",
        modelCode: 2,
        firmwareVersion: 0x089A,
        buttons: [button],
        lighting: [originalLighting],
        colorTables: [indexed],
        scriptNames: [SayoNamedSlot(number: 0, name: "Tap A", rawName: Array("Tap A".utf8))],
        scriptImage: tapScript,
        deviceName: "SayoDevice O2L V2",
        strings: [indexed]
    )
    let backupData = try JSONEncoder().encode(backup)
    let decodedBackup = try JSONDecoder().decode(SayoDeviceBackup.self, from: backupData)
    try check(decodedBackup == backup, "device backup did not round-trip")

    let completedRollout = Data("""
    {"timestamp":"2026-08-30T02:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":1788055200}}
    {"timestamp":"2026-08-30T02:01:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","started_at":1788055200,"completed_at":1788055260}}
    """.utf8)
    let completedLifecycle = CodexActivityService.decodeLastLifecycleEvent(from: completedRollout)
    try check(completedLifecycle?.kind == .completed, "Codex lifecycle parser did not detect a completed task")
    try check(completedLifecycle?.timestamp == 1_788_055_260, "Codex lifecycle parser used the wrong completion timestamp")

    let workingRollout = completedRollout + Data("\n".utf8) + Data("""
    {"timestamp":"2026-08-30T02:02:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2","started_at":1788055320}}
    """.utf8)
    let workingLifecycle = CodexActivityService.decodeLastLifecycleEvent(from: workingRollout)
    try check(workingLifecycle?.kind == .started, "Codex lifecycle parser did not detect a running task")
    try check(workingLifecycle?.timestamp == 1_788_055_320, "Codex lifecycle parser used the wrong start timestamp")

    let interruptedRollout = workingRollout + Data("\n".utf8) + Data("""
    {"timestamp":"2026-08-30T02:03:00.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}
    """.utf8)
    let interruptedLifecycle = CodexActivityService.decodeLastLifecycleEvent(from: interruptedRollout)
    try check(interruptedLifecycle?.kind == .interrupted, "Codex lifecycle parser did not detect an interrupted task")
    try check(interruptedLifecycle?.timestamp == 1_788_055_380, "Codex lifecycle parser did not decode the abort timestamp")

    func event(_ key: HyperdeckKey, _ phase: HyperdeckKeyPhase, _ timestamp: TimeInterval) -> HyperdeckPhysicalEvent {
        HyperdeckPhysicalEvent(key: key, phase: phase, timestamp: timestamp)
    }

    var leftTap = HyperdeckGestureRecognizer()
    try check(leftTap.handle(event(.left, .down, 0)).isEmpty, "left-tap recognizer emitted on key down")
    try check(abs((leftTap.nextDeadline ?? 0) - 0.45) < 0.001, "left hold deadline was not scheduled")
    try check(leftTap.handle(event(.left, .up, 0.05)).isEmpty, "left-tap recognizer did not wait for double-tap ambiguity")
    try check(abs((leftTap.nextDeadline ?? 0) - 0.30) < 0.001, "deferred left tap deadline was not scheduled")
    try check(leftTap.flush(at: 0.31) == [.leftTap], "left tap was not emitted after the sequence window")
    try check(leftTap.nextDeadline == nil, "left tap left an unnecessary timer deadline")

    var rightHold = HyperdeckGestureRecognizer()
    _ = rightHold.handle(event(.right, .down, 1))
    try check(abs((rightHold.nextDeadline ?? 0) - 1.45) < 0.001, "right hold deadline was not scheduled")
    try check(rightHold.flush(at: 1.46) == [.rightHold], "right hold was not emitted while the key remained down")
    try check(rightHold.nextDeadline == nil, "emitted right hold left an unnecessary timer deadline")
    try check(rightHold.handle(event(.right, .up, 1.6)).isEmpty, "right hold was emitted twice on release")

    var leftDoubleTap = HyperdeckGestureRecognizer()
    _ = leftDoubleTap.handle(event(.left, .down, 2))
    _ = leftDoubleTap.handle(event(.left, .up, 2.04))
    _ = leftDoubleTap.handle(event(.left, .down, 2.12))
    try check(leftDoubleTap.handle(event(.left, .up, 2.16)) == [.leftDoubleTap], "left double-tap was classified incorrectly")

    var orderedSequence = HyperdeckGestureRecognizer()
    _ = orderedSequence.handle(event(.right, .down, 3))
    _ = orderedSequence.handle(event(.right, .up, 3.04))
    _ = orderedSequence.handle(event(.left, .down, 3.12))
    try check(orderedSequence.handle(event(.left, .up, 3.16)) == [.rightThenLeft], "ordered two-key sequence was classified incorrectly")

    var bothTap = HyperdeckGestureRecognizer()
    _ = bothTap.handle(event(.left, .down, 4))
    _ = bothTap.handle(event(.right, .down, 4.04))
    _ = bothTap.handle(event(.left, .up, 4.1))
    try check(bothTap.handle(event(.right, .up, 4.12)) == [.bothTap], "two-key chord was not classified as both-tap")

    var bothHold = HyperdeckGestureRecognizer()
    _ = bothHold.handle(event(.left, .down, 5))
    _ = bothHold.handle(event(.right, .down, 5.04))
    try check(abs((bothHold.nextDeadline ?? 0) - 6.5) < 0.001, "both-key hold deadline was not scheduled")
    try check(bothHold.flush(at: 6.55) == [.bothHold], "both-key hold did not fire at its threshold")
    _ = bothHold.handle(event(.left, .up, 6.6))
    try check(bothHold.handle(event(.right, .up, 6.62)).isEmpty, "both-key hold was emitted twice on release")

    var normalizedTiming = HyperdeckGestureTiming(chordWindow: 0.25, sequenceWindow: 99, holdThreshold: 0.2, bothHoldThreshold: 0.1)
    normalizedTiming.normalize()
    try check(normalizedTiming.holdThreshold >= normalizedTiming.chordWindow, "timing normalization allowed holds to preempt the chord window")
    try check(normalizedTiming.sequenceWindow == 0.8, "timing normalization did not clamp the sequence window")
    try check(normalizedTiming.bothHoldThreshold >= normalizedTiming.holdThreshold, "timing normalization allowed both-hold below single-hold")

    let hyperdeckDefaults = HyperdeckConfiguration.defaults
    let fallbackProfile = try hyperdeckDefaults.profiles.first(where: { $0.bundleIdentifiers.isEmpty })
        .unwrap(or: "Hyperdeck defaults are missing a fallback profile")
    let xcodeProfile = try hyperdeckDefaults.profiles.first(where: { $0.name == "Xcode" })
        .unwrap(or: "Hyperdeck defaults are missing the Xcode profile")
    try check(HyperdeckGesture.allCases.allSatisfy { hyperdeckDefaults.recipeID(for: $0, profileID: fallbackProfile.id) != nil }, "fallback profile does not assign every gesture")
    try check(hyperdeckDefaults.recipeID(for: .leftTap, profileID: xcodeProfile.id) == hyperdeckDefaults.recipeID(for: .leftTap, profileID: fallbackProfile.id), "smart-profile fallback did not inherit an unassigned gesture")
    let hyperdeckRoundTrip = try JSONDecoder().decode(HyperdeckConfiguration.self, from: JSONEncoder().encode(hyperdeckDefaults))
    try check(hyperdeckRoundTrip == hyperdeckDefaults, "Hyperdeck configuration did not round-trip through JSON")

    print("PASS: protocol, official-feature catalog, backup, Lighting v2, Codex Deck, Codex lifecycle, and Hyperdeck gesture assertions")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}

private extension Optional {
    func unwrap(or message: String) throws -> Wrapped {
        guard let self else { throw CheckFailure.failed(message) }
        return self
    }
}
