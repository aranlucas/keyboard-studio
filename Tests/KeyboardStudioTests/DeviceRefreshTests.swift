import Foundation
import Testing
@testable import KeyboardCore
@testable import KeyboardStudio

private struct DeniedHID: SayoHIDTransport {
    func accessStatus() -> SayoKeyboardAccessStatus { .denied }
    func requestAccess() -> Bool { false }
    func findDevice() throws -> DeviceIdentity { throw SayoDeviceServiceError.keyboardAccessRequired }
    func transact(_ packet: SayoPacket, boundTo identity: DeviceIdentity) throws -> SayoPacket {
        throw SayoDeviceServiceError.keyboardAccessRequired
    }
}

struct DeviceRefreshTests {
    // Refresh must not leave pad A's secrets/settings available for pad B,
    // even when the new connection cannot be read.
    @Test @MainActor
    func failedRefreshDiscardsPriorDeviceSettingsAndSecretConsent() async {
        let model = AppModel(deviceService: SayoDeviceService(transport: DeniedHID()), startsAutomatically: false)
        model.passwordSlots = [.init(number: 0, name: "fixture-secret", rawName: [])]
        model.secretsAreLoaded = true
        model.includeSecretsInBackup = true
        model.editableDeviceName = "Previous pad"
        model.scriptImage = [1, 2, 0xFF, 0xFF]
        model.stringSlots = [.init(number: 0, mode: 0, values: [42])]
        await model.refreshDevice()
        #expect(model.deviceSnapshot == nil)
        #expect(model.passwordSlots.isEmpty)
        #expect(!model.secretsAreLoaded)
        #expect(!model.includeSecretsInBackup)
        #expect(model.editableDeviceName.isEmpty)
        #expect(model.scriptImage.isEmpty)
        #expect(model.stringSlots.isEmpty)
    }
}
