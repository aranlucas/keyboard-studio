import Carbon.HIToolbox
import Foundation
import KeyboardCore

/// Registers only the two dedicated function keys used by Codex Deck.
///
/// Carbon hot keys are deliberately used instead of an NSEvent global monitor:
/// the app receives F13/F16 activations without observing arbitrary keystrokes or
/// requiring Accessibility permission.
@MainActor
final class CodexDeckHotKeyController {
    enum RegistrationError: LocalizedError {
        case installHandler(OSStatus)
        case registerKey(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case let .installHandler(status):
                "Could not install the Codex Deck hot-key handler (OSStatus \(status))."
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
    private let onAction: (CodexDeckAction) -> Void

    init(onAction: @escaping (CodexDeckAction) -> Void) throws {
        self.onAction = onAction

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventType,
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

    private func handle(id: UInt32) {
        switch id {
        case Self.openCodexID:
            onAction(.openCodex)
        case Self.acknowledgeID:
            onAction(.acknowledge)
        default:
            break
        }
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

        let controller = Unmanaged<CodexDeckHotKeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        MainActor.assumeIsolated {
            controller.handle(id: hotKeyID.id)
        }
        return OSStatus(noErr)
    }
}
