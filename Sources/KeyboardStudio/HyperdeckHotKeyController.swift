import Carbon.HIToolbox
import Foundation
import KeyboardCore

/// Registers only the two dedicated function keys used by Hyperdeck.
///
/// Carbon hot keys are deliberately used instead of an NSEvent global monitor:
/// the app receives F13/F16 activations without observing arbitrary keystrokes or
/// requiring Accessibility permission.
@MainActor
final class HyperdeckHotKeyController {
    enum RegistrationError: LocalizedError {
        case installHandler(OSStatus)
        case registerKey(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case let .installHandler(status):
                "Could not install the Hyperdeck hot-key handler (OSStatus \(status))."
            case let .registerKey(key, status):
                "Could not register \(key) as a Codex Deck hot key (OSStatus \(status))."
            }
        }
    }

    private static let signature: OSType = 0x4344_584B // "CDXK"
    private static let openCodexID: UInt32 = 1
    private static let acknowledgeID: UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var openCodexHotKey: EventHotKeyRef?
    private var acknowledgeHotKey: EventHotKeyRef?
    private let onEvent: (HyperdeckPhysicalEvent) -> Void

    init(onEvent: @escaping (HyperdeckPhysicalEvent) -> Void) throws {
        self.onEvent = onEvent

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw RegistrationError.installHandler(handlerStatus)
        }

        do {
            try register(
                keyCode: UInt32(kVK_F13),
                id: Self.openCodexID,
                label: "F13",
                reference: &openCodexHotKey
            )
            try register(
                keyCode: UInt32(kVK_F16),
                id: Self.acknowledgeID,
                label: "F16",
                reference: &acknowledgeHotKey
            )
        } catch {
            tearDown()
            throw error
        }
    }

    isolated deinit {
        if let openCodexHotKey {
            UnregisterEventHotKey(openCodexHotKey)
        }
        if let acknowledgeHotKey {
            UnregisterEventHotKey(acknowledgeHotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func register(
        keyCode: UInt32,
        id: UInt32,
        label: String,
        reference: inout EventHotKeyRef?
    ) throws {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else {
            throw RegistrationError.registerKey(label, status)
        }
    }

    private func handle(id: UInt32, phase: HyperdeckKeyPhase) {
        let key: HyperdeckKey
        switch id {
        case Self.openCodexID: key = .left
        case Self.acknowledgeID: key = .right
        default: return
        }
        onEvent(HyperdeckPhysicalEvent(
            key: key,
            phase: phase,
            timestamp: ProcessInfo.processInfo.systemUptime
        ))
    }

    private func tearDown() {
        if let openCodexHotKey {
            UnregisterEventHotKey(openCodexHotKey)
            self.openCodexHotKey = nil
        }
        if let acknowledgeHotKey {
            UnregisterEventHotKey(acknowledgeHotKey)
            self.acknowledgeHotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private static let eventHandlerCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }

        let controller = Unmanaged<HyperdeckHotKeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        let phase: HyperdeckKeyPhase = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .down : .up
        MainActor.assumeIsolated {
            controller.handle(id: hotKeyID.id, phase: phase)
        }
        return OSStatus(noErr)
    }
}
