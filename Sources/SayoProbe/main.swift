import Foundation
import KeyboardCore

@main
struct SayoProbe {
    static func main() async {
        do {
            let service = SayoDeviceService()
            let arguments = CommandLine.arguments
            if arguments.contains("--codex-status") {
                let status = await CodexActivityService().runtimeStatus()
                try printJSON(status)
                return
            }
            if arguments.contains("--read-lighting-v2") {
                var lighting: [SayoLightingV2Configuration] = []
                for number in UInt8(0) ..< UInt8(8) {
                    guard let configuration = try? await service.readLightingV2(number: number) else {
                        break
                    }
                    lighting.append(configuration)
                }
                try printJSON(lighting)
                return
            }
            if let optionIndex = arguments.firstIndex(of: "--read-indexed") {
                let values = Array(arguments.dropFirst(optionIndex + 1))
                guard let value = values.first,
                      let command = UInt8(value, radix: value.lowercased().hasPrefix("0x") ? 16 : 10)
                        ?? UInt8(value.replacingOccurrences(of: "0x", with: ""), radix: 16)
                else {
                    fputs("usage: sayo-probe --read-indexed COMMAND [LIMIT]\n", stderr)
                    exit(2)
                }
                let limit = values.dropFirst().first.flatMap(Int.init) ?? 256
                try printJSON(try await service.readIndexedRecords(command: command, limit: limit))
                return
            }
            if arguments.contains("--read-device-name") {
                try printJSON(["name": try await service.readDeviceName()])
                return
            }
            if arguments.contains("--read-device-identity") {
                try printJSON(try await service.readDeviceIdentityConfiguration())
                return
            }
            if let optionIndex = arguments.firstIndex(of: "--read-named-slots") {
                let values = Array(arguments.dropFirst(optionIndex + 1))
                guard let value = values.first,
                      let command = UInt8(value.replacingOccurrences(of: "0x", with: ""), radix: 16)
                else {
                    fputs("usage: sayo-probe --read-named-slots COMMAND [LIMIT]\n", stderr)
                    exit(2)
                }
                let limit = values.dropFirst().first.flatMap(Int.init) ?? 64
                try printJSON(try await service.readNamedSlots(command: command, limit: limit))
                return
            }
            if arguments.contains("--read-script-image") {
                let image = try await service.readRawScriptImage()
                try printJSON(image)
                return
            }
            if let optionIndex = arguments.firstIndex(of: "--set-lighting-v2-raw") {
                let values = Array(arguments.dropFirst(optionIndex + 1))
                guard values.count >= 3,
                      let number = UInt8(values[0]),
                      let mode = UInt8(values[1])
                else {
                    fputs("usage: sayo-probe --set-lighting-v2-raw LED MODE VALUE...\n", stderr)
                    exit(2)
                }
                let rawValues = try values.dropFirst(2).map { value -> UInt8 in
                    guard let byte = UInt8(value) else {
                        throw SayoProtocolError.invalidPacket("Lighting v2 raw values must be UInt8 integers")
                    }
                    return byte
                }
                let requested = SayoLightingV2Configuration(
                    number: number,
                    mode: mode,
                    values: rawValues
                )
                let echoed = try await service.writeLightingV2(requested)
                try printJSON(echoed)
                return
            }
            if let optionIndex = arguments.firstIndex(of: "--set-static-lighting-v2") {
                let values = arguments.dropFirst(optionIndex + 1).prefix(4)
                guard values.count == 4,
                      let number = UInt8(values[values.startIndex]),
                      let red = UInt8(values[values.index(values.startIndex, offsetBy: 1)]),
                      let green = UInt8(values[values.index(values.startIndex, offsetBy: 2)]),
                      let blue = UInt8(values[values.index(values.startIndex, offsetBy: 3)])
                else {
                    fputs("usage: sayo-probe --set-static-lighting-v2 LED RED GREEN BLUE\n", stderr)
                    exit(2)
                }
                let current = try await service.readLightingV2(number: number)
                let requested = try current.settingStaticColor(
                    red: red,
                    green: green,
                    blue: blue
                )
                let echoed = try await service.writeLightingV2(requested)
                try printJSON(echoed)
                return
            }
            var snapshot = try await service.readSnapshot()
            if CommandLine.arguments.contains("--install-codex-deck") {
                let configured = try CodexDeckProfile.applying(to: snapshot.buttons)
                _ = try await service.writeAndSave(buttons: configured)
                snapshot = try await service.readSnapshot()
                guard CodexDeckProfile.isInstalled(in: snapshot.buttons) else {
                    throw SayoProtocolError.invalidPacket("Codex Deck did not verify after flash commit")
                }
                fputs("Installed and verified Codex Deck (F13/F16).\n", stderr)
            }
            try printJSON(snapshot)
        } catch {
            fputs("sayo-probe: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }
}
