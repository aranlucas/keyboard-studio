import Foundation

public enum CodexDeckProfile {
    public static let openCodexHIDKey: UInt8 = 0x68 // F13
    public static let acknowledgeHIDKey: UInt8 = 0x6B // F16
    public static let openCodexVirtualKey: UInt16 = 105
    public static let acknowledgeVirtualKey: UInt16 = 106
    public static let layerIndex = 0

    public static func applying(
        to buttons: [SayoButtonConfiguration],
        layerIndex: Int = layerIndex
    ) throws -> [SayoButtonConfiguration] {
        guard buttons.count >= 2,
              layerIndex >= 0,
              buttons[0].layers.indices.contains(layerIndex),
              buttons[1].layers.indices.contains(layerIndex)
        else {
            throw SayoProtocolError.unsupportedConfiguration
        }

        var updated = buttons
        let keyCodes = [openCodexHIDKey, acknowledgeHIDKey]
        for buttonIndex in 0 ..< 2 {
            let existing = updated[buttonIndex].layers[layerIndex]
            updated[buttonIndex].layers[layerIndex] = SayoKeyLayer(
                id: existing.id,
                mode: 0,
                reserved: existing.reserved,
                modifier: 0,
                keyCodes: [keyCodes[buttonIndex], 0, 0]
            )
        }
        return updated
    }

    public static func isInstalled(
        in buttons: [SayoButtonConfiguration],
        layerIndex: Int = layerIndex
    ) -> Bool {
        guard buttons.count >= 2,
              layerIndex >= 0,
              buttons[0].layers.indices.contains(layerIndex),
              buttons[1].layers.indices.contains(layerIndex)
        else { return false }

        let first = buttons[0].layers[layerIndex]
        let second = buttons[1].layers[layerIndex]
        return first.mode == 0
            && first.modifier == 0
            && first.keyCodes == [openCodexHIDKey, 0, 0]
            && second.mode == 0
            && second.modifier == 0
            && second.keyCodes == [acknowledgeHIDKey, 0, 0]
    }

    public static func action(forVirtualKeyCode keyCode: UInt16) -> CodexDeckAction? {
        switch keyCode {
        case openCodexVirtualKey: .openCodex
        case acknowledgeVirtualKey: .acknowledge
        default: nil
        }
    }
}

public enum CodexDeckAction: Sendable {
    case openCodex
    case acknowledge
}
