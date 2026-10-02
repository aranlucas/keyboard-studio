import Foundation
import Testing
@testable import KeyboardCore

private func light(_ number: UInt8, _ red: UInt8) -> SayoLightingV2Configuration {
    SayoLightingV2Configuration(number: number, mode: 0, values: [0, 0, 0, red, 0, 0, 0, 0, 0])
}

/// No HID, filesystem, live Codex state, or hardware is accessed by this adapter.
private final class ScriptedHID: SayoHIDTransport, @unchecked Sendable {
    struct State {
        var identity = DeviceIdentity(product: "Test pad", manufacturer: "Test", serialNumber: "test-1",
                                      vendorID: 0x8089, productID: 0x000C, locationID: 1)
        var lights: [UInt8: SayoLightingV2Configuration] = [0: light(0, 10), 1: light(1, 20)]
        var palettes: [Int: SayoIndexedRecord] = [:]
        var flashes: [[UInt8: SayoLightingV2Configuration]] = []
        var requests: [SayoPacket] = []
        var targets: [DeviceIdentity] = []
        var mismatchLight: UInt8?
        var rejectFlash = false
        var disconnectCommand: UInt8?
        var failStatusAfterFlash = false
        var scriptBytes: [UInt8] = []
        var corruptScriptTerminator = false
        var wrongScriptSlot = false
        var deviceName: [UInt8] = []
        var passwords: [UInt8: [UInt8]] = [:]
        var gate: Gate?
    }
    final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }
    private let lock = NSLock()
    private var state = State()
    func inspect() -> State { lock.withLock { state } }
    func configure(_ edit: (inout State) -> Void) { lock.withLock { edit(&state) } }
    func accessStatus() -> SayoKeyboardAccessStatus { .granted }
    func requestAccess() -> Bool { true }
    func findDevice() throws -> DeviceIdentity { inspect().identity }

    func transact(_ packet: SayoPacket, boundTo identity: DeviceIdentity) throws -> SayoPacket {
        let gate = lock.withLock { () -> Gate? in
            guard packet.command == 0x10, packet.payload.first == 1 else { return nil }
            let gate = state.gate
            state.gate = nil
            return gate
        }
        if let gate {
            gate.entered.signal()
            guard gate.release.wait(timeout: .now() + 10) == .success else {
                throw SayoDeviceServiceError.transport("Test gate timed out")
            }
        }
        return try lock.withLock {
            state.requests.append(packet)
            state.targets.append(identity)
            guard identity == state.identity else {
                throw SayoDeviceServiceError.transport("Selected physical keyboard is unavailable")
            }
            if state.disconnectCommand == packet.command {
                throw SayoDeviceServiceError.transport("Scripted disconnect")
            }
            _ = try packet.encoded()
            switch packet.command {
            case 0:
                return SayoPacket(command: 0, payload: [0, 1, 0, 1, 0, 0, 0, 0, 22, 0x10])
            case 22:
                if packet.payload.first == 1 { return SayoPacket(command: 0, payload: packet.payload) }
                var header = [UInt8](repeating: 0, count: 16)
                header[1] = packet.payload[1]
                return SayoPacket(command: 0, payload: header + [0, 0, 0x04, 0, 0, 0, 0, 0])
            case 0x10:
                let number = packet.payload[1]
                if packet.payload.first == 1 {
                    let value = SayoLightingV2Configuration(number: number, mode: packet.payload[2],
                                                           values: Array(packet.payload.dropFirst(3)))
                    if state.failStatusAfterFlash, !state.flashes.isEmpty, value.red == 99 {
                        throw SayoDeviceServiceError.transport("Status lamp write failed")
                    }
                    state.lights[number] = value
                    if state.mismatchLight == number {
                        var mismatched = packet.payload
                        mismatched[2] ^= 1
                        return SayoPacket(command: 0, payload: mismatched)
                    }
                }
                let value = state.lights[number] ?? light(number, 0)
                return SayoPacket(command: 0, payload: [0, number, value.mode] + value.values)
            case 0x11, 0x0C:
                let record = try SayoIndexedRecord.decode(response: SayoPacket(command: 0, payload: packet.payload),
                                                         requestCommand: packet.command)
                state.palettes[record.number] = record
                return SayoPacket(command: 0, payload: packet.payload)
            case 0xF1:
                var payload = packet.payload
                if state.wrongScriptSlot { payload[1] &+= 1 }
                return SayoPacket(command: 0, payload: payload)
            case 0x08:
                if packet.payload.first == 1 { state.deviceName = Array(packet.payload.dropFirst()) }
                return SayoPacket(command: 0, payload: [0] + state.deviceName)
            case 0x0B:
                let number = packet.payload[1]
                if packet.payload.first == 1 { state.passwords[number] = Array(packet.payload.dropFirst(2)) }
                return SayoPacket(command: 0, payload: [0, number] + (state.passwords[number] ?? [0]))
            case 0xF0:
                let address = Int(packet.payload[0]) << 8 | Int(packet.payload[1])
                if packet.payload.count > 2 {
                    let bytes = Array(packet.payload.dropFirst(2))
                    if state.scriptBytes.count < address + bytes.count {
                        state.scriptBytes += [UInt8](repeating: 0, count: address + bytes.count - state.scriptBytes.count)
                    }
                    state.scriptBytes.replaceSubrange(address ..< address + bytes.count, with: bytes)
                    if state.corruptScriptTerminator, state.scriptBytes.last == 0xFF {
                        state.scriptBytes[state.scriptBytes.count - 1] = 0
                    }
                    return SayoPacket(command: 0)
                }
                return SayoPacket(command: 0, payload: Array(state.scriptBytes.dropFirst(address).prefix(60)))
            case 4:
                if state.rejectFlash { return SayoPacket(command: 0xEE) }
                state.flashes.append(state.lights)
                return SayoPacket(command: 0)
            default:
                throw SayoDeviceServiceError.transport("Unexpected scripted command")
            }
        }
    }
}

struct SayoConfigurationCommitTests {
    private func selected(_ transport: ScriptedHID) async throws -> (SayoDeviceService, SayoDeviceSnapshot) {
        let service = SayoDeviceService(transport: transport)
        return (service, try await service.readSnapshot())
    }

    @Test(arguments: [
        SayoConfigurationPlan(lighting: [SayoLightingV2Configuration(number: 0, mode: 0, values: [])]),
        SayoConfigurationPlan(lighting: [light(0, 30), light(0, 40)]),
        SayoConfigurationPlan(colorTables: [SayoIndexedRecord(number: 0, mode: 0, values: [1])],
                              strings: [SayoIndexedRecord(number: -1, mode: 0, values: [])]),
        SayoConfigurationPlan(scriptSlots: [SayoNamedSlot(number: 256, name: "Invalid", rawName: [])]),
    ])
    func malformedPlansSendNoPackets(_ plan: SayoConfigurationPlan) async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        let before = transport.inspect().requests.count
        await #expect(throws: SayoProtocolError.self) {
            try await service.commitConfiguration(plan, expectedDevice: snapshot)
        }
        #expect(transport.inspect().requests.count == before)
    }

    @Test
    func failedRefreshKeepsTheOriginalLampBaselineForRetry() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        try await service.setStatusFrame([SayoStatusLight(number: 0, red: 99, green: 0, blue: 0)], expectedDevice: snapshot)
        transport.configure { $0.disconnectCommand = 0x10 }
        await #expect(throws: SayoDeviceServiceError.self) { try await service.readSnapshot() }
        transport.configure { $0.disconnectCommand = nil }
        let refreshed = try await service.readSnapshot()
        #expect(transport.inspect().lights[0]?.red == 10)
        _ = try await service.commitConfiguration(SayoConfigurationPlan(), expectedDevice: refreshed)
        #expect(transport.inspect().flashes[0][0]?.red == 10)
    }

    @Test
    func invalidLaterRecordSendsNoWritesOrFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        try await service.setStatusFrame([SayoStatusLight(number: 0, red: 99, green: 0, blue: 0)], expectedDevice: snapshot)
        let before = transport.inspect().requests.count
        do {
            _ = try await service.commitConfiguration(SayoConfigurationPlan(
                lighting: [light(0, 30)],
                scriptSlots: [SayoNamedSlot(number: 0, name: "valid", rawName: [])],
                scriptImage: [UInt8](repeating: 1, count: SayoDeviceBackup.maximumScriptImageBytes)
            ), expectedDevice: snapshot)
            Issue.record("Invalid plan unexpectedly succeeded")
        } catch is SayoProtocolError {}
        #expect(transport.inspect().requests.count == before)
        #expect(transport.inspect().flashes.isEmpty)
        #expect(transport.inspect().lights[0]?.red == 99)
    }

    @Test
    func verificationMismatchReportsPartialVolatileStateAndBlocksAnotherFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        transport.configure { $0.mismatchLight = 1 }
        do {
            _ = try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 30), light(1, 40)]),
                                                      expectedDevice: snapshot)
            Issue.record("Mismatched echo unexpectedly succeeded")
        } catch let failure as SayoConfigurationCommitError {
            #expect(failure.phase == .writing)
            #expect(failure.verifiedRecordCount == 1)
            #expect(!failure.flashMayHaveOccurred)
        }
        #expect(transport.inspect().lights[0]?.red == 30)
        #expect(transport.inspect().lights[1]?.red == 40)
        #expect(transport.inspect().flashes.isEmpty)
        await #expect(throws: SayoDeviceServiceError.self) { try await service.saveToFlash() }
        #expect(transport.inspect().flashes.isEmpty)
        transport.configure { $0.mismatchLight = nil }
        let refreshed = try await service.readSnapshot()
        _ = try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 10), light(1, 20)]),
                                                  expectedDevice: refreshed)
        #expect(transport.inspect().flashes.count == 1)
    }

    @Test
    func unrelatedSaveSuspendsLampAndReappliesItOnlyAfterFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        let original = transport.inspect().lights
        try await service.setStatusFrame([SayoStatusLight(number: 0, red: 99, green: 0, blue: 0)], expectedDevice: snapshot)
        let palette = SayoIndexedRecord(number: 0, mode: 0, values: [1, 2, 3])
        let result = try await service.commitConfiguration(SayoConfigurationPlan(colorTables: [palette]),
                                                          expectedDevice: snapshot)
        #expect(result.verified.colorTables == [palette])
        #expect(result.statusLampWarning == nil)
        #expect(transport.inspect().flashes == [original])
        #expect(transport.inspect().lights[0]?.red == 99)
        try await service.setStatusFrame([], expectedDevice: snapshot)
        #expect(transport.inspect().lights == original)
    }

    @Test
    func lightingCommitUpdatesBaselineInsteadOfSavingOrRestoringOldLampValues() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        try await service.setStatusFrame([SayoStatusLight(number: 0, red: 99, green: 0, blue: 0)], expectedDevice: snapshot)
        let result = try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 55)]), expectedDevice: snapshot)
        #expect(result.verified.lighting == [light(0, 55)])
        #expect(transport.inspect().flashes[0][0]?.red == 55)
        #expect(transport.inspect().lights[0]?.red == 99)
        try await service.setStatusFrame([], expectedDevice: snapshot)
        #expect(transport.inspect().lights[0]?.red == 55)
    }

    @Test
    func postFlashLampFailureIsAWarningOnSuccessfulCommit() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        try await service.setStatusFrame([SayoStatusLight(number: 0, red: 99, green: 0, blue: 0)], expectedDevice: snapshot)
        transport.configure { $0.failStatusAfterFlash = true }
        let result = try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 55)]), expectedDevice: snapshot)
        #expect(result.verified.lighting == [light(0, 55)])
        #expect(result.statusLampWarning != nil)
        #expect(transport.inspect().flashes.count == 1)
        #expect(transport.inspect().flashes[0][0]?.red == 55)
    }

    @Test
    func rejectedFlashNeverReportsSuccess() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        transport.configure { $0.rejectFlash = true }
        do {
            _ = try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 55)]), expectedDevice: snapshot)
            Issue.record("Rejected flash unexpectedly succeeded")
        } catch let failure as SayoConfigurationCommitError {
            #expect(failure.phase == .flashing)
            #expect(failure.flashMayHaveOccurred)
            #expect(failure.verifiedRecordCount == 1)
        }
        #expect(transport.inspect().flashes.isEmpty)
    }

    @Test
    func disconnectedWriteDoesNotFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        transport.configure { $0.disconnectCommand = 0x10 }
        do {
            _ = try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 55)]), expectedDevice: snapshot)
            Issue.record("Disconnected write unexpectedly succeeded")
        } catch let failure as SayoConfigurationCommitError {
            #expect(failure.phase == .writing)
            #expect(!failure.flashMayHaveOccurred)
        }
        #expect(transport.inspect().flashes.isEmpty)
    }

    @Test
    func staleExpectedIdentitySendsNoPackets() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        var other = snapshot
        other.serialNumber = "another-pad"
        let before = transport.inspect().requests.count
        await #expect(throws: SayoDeviceServiceError.self) {
            try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 55)]), expectedDevice: other)
        }
        #expect(transport.inspect().requests.count == before)
        await service.clearSelection()
        await #expect(throws: SayoDeviceServiceError.self) {
            try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 55)]), expectedDevice: snapshot)
        }
        #expect(transport.inspect().requests.count == before)
    }

    @Test
    func scriptsVerifyTheTerminatorBeforeFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        transport.configure { $0.corruptScriptTerminator = true }
        await #expect(throws: SayoConfigurationCommitError.self) {
            try await service.commitConfiguration(SayoConfigurationPlan(scriptImage: [0x01, 0x02]), expectedDevice: snapshot)
        }
        #expect(transport.inspect().flashes.isEmpty)
    }

    @Test
    func allConfigurationFamiliesShareOneVerifiedFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        let palette = SayoIndexedRecord(number: 0, mode: 0, values: [1, 2, 3])
        let text = SayoIndexedRecord(number: 1, mode: 0, values: [0, 65])
        let plan = SayoConfigurationPlan(
            buttons: snapshot.buttons, lighting: [light(0, 55)], colorTables: [palette],
            scriptSlots: [SayoNamedSlot(number: 0, name: "Test script", rawName: [])],
            scriptImage: [1, 2, 3], passwords: [SayoNamedSlot(number: 1, name: "Test only", rawName: [])],
            strings: [text], deviceName: "Test pad"
        )
        let result = try await service.commitConfiguration(plan, expectedDevice: snapshot)
        #expect(result.verified.buttons == snapshot.buttons.map { button in
            var verified = button
            verified.header[0] = 1
            return verified
        })
        #expect(result.verified.lighting == plan.lighting)
        #expect(result.verified.colorTables == plan.colorTables)
        #expect(result.verified.scriptSlots.first?.name == "Test script")
        #expect(result.verified.passwords.first?.name == "Test only")
        #expect(result.verified.strings == [text])
        #expect(result.verified.deviceName == "Test pad")
        #expect(transport.inspect().scriptBytes == [1, 2, 3, 0xFF, 0xFF])
        #expect(transport.inspect().flashes.count == 1)
        #expect(transport.inspect().requests.last?.command == 4)
    }

    @Test
    func wrongScriptSlotEchoPreventsBytecodeWriteAndFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        transport.configure { $0.wrongScriptSlot = true }
        await #expect(throws: SayoConfigurationCommitError.self) {
            try await service.commitConfiguration(SayoConfigurationPlan(
                scriptSlots: [SayoNamedSlot(number: 0, name: "Test script", rawName: [])], scriptImage: [1]
            ), expectedDevice: snapshot)
        }
        #expect(transport.inspect().scriptBytes.isEmpty)
        #expect(transport.inspect().flashes.isEmpty)
    }

    @Test
    func failedLampSuspensionPreventsConfigurationWritesAndFlash() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        try await service.setStatusFrame([SayoStatusLight(number: 0, red: 99, green: 0, blue: 0)], expectedDevice: snapshot)
        transport.configure { $0.disconnectCommand = 0x10 }
        do {
            _ = try await service.commitConfiguration(SayoConfigurationPlan(
                colorTables: [SayoIndexedRecord(number: 0, mode: 0, values: [1])]
            ), expectedDevice: snapshot)
            Issue.record("Commit proceeded without suspending the lamp")
        } catch let failure as SayoConfigurationCommitError {
            #expect(failure.phase == .restoringLighting)
            #expect(failure.verifiedRecordCount == 0)
            #expect(!failure.flashMayHaveOccurred)
        }
        #expect(transport.inspect().palettes.isEmpty)
        #expect(transport.inspect().flashes.isEmpty)
    }

    @Test
    func replacementKeyboardIsNeverUsedMidCommit() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        let gate = ScriptedHID.Gate()
        transport.configure { $0.gate = gate }
        let commit = Task {
            try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 30), light(1, 40)]),
                                                  expectedDevice: snapshot)
        }
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 10) == .success }.value
        #expect(entered)
        transport.configure {
            $0.identity = DeviceIdentity(product: "Test pad", manufacturer: "Test", serialNumber: "test-2",
                                         vendorID: 0x8089, productID: 0x000C, locationID: 2)
        }
        gate.release.signal()
        await #expect(throws: SayoConfigurationCommitError.self) { try await commit.value }
        #expect(transport.inspect().targets.allSatisfy { $0.matches(snapshot) })
        #expect(transport.inspect().flashes.isEmpty)
        #expect(transport.inspect().lights[0]?.red == 10)
    }

    @Test
    func concurrentCommitsAndStatusFrameCannotInterleaveRecords() async throws {
        let transport = ScriptedHID()
        let (service, snapshot) = try await selected(transport)
        let gate = ScriptedHID.Gate()
        transport.configure { $0.gate = gate }
        let first = Task {
            try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 30), light(1, 40)]),
                                                  expectedDevice: snapshot)
        }
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 10) == .success }.value
        #expect(entered)
        let second = Task {
            try await service.commitConfiguration(SayoConfigurationPlan(lighting: [light(0, 50), light(1, 60)]),
                                                  expectedDevice: snapshot)
        }
        let status = Task {
            try await service.setStatusFrame([SayoStatusLight(number: 0, red: 99, green: 0, blue: 0)], expectedDevice: snapshot)
        }
        await Task.yield()
        gate.release.signal()
        _ = try await first.value
        _ = try await second.value
        try await status.value
        let flashes = transport.inspect().flashes
        #expect(flashes.count == 2)
        #expect(flashes[0][0]?.red == 30 && flashes[0][1]?.red == 40)
        #expect(flashes[1][0]?.red == 50 && flashes[1][1]?.red == 60)
        #expect(transport.inspect().targets.allSatisfy { $0.matches(snapshot) })
        try await service.setStatusFrame([], expectedDevice: snapshot)
        #expect(transport.inspect().lights[0]?.red == 50)
    }
}
