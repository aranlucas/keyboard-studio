# SayoDevice O2L V2 reverse-engineering report

Date: 2026-08-29  
Scope: locally owned second USB keyboard; read and configuration protocol only

## Outcome

The second keyboard is a **SayoDevice O2L V2**, not a passive two-switch keyboard. It is a composite USB HID device with ordinary keyboard, mouse, consumer-control, and two vendor-defined application collections. Configuration is carried in 64-byte HID reports on report ID `0x02`.

A native SwiftUI configurator was built around the recovered protocol. Version 0.4.0 covers two button maps, all reported layers, the official key action-mode catalog, Lighting v2 effects and six palettes, one-key strings/passwords, script names and bytecode, device naming/identity, staged backup/restore, verified flash saves, local Codex task activity, optional macOS notifications, and capability-gated RGB activity indication. Its Codex Deck profile reserves F13/F16 on Layer 1 for opening Codex and acknowledging activity while preserving the other layer. F16 avoids macOS's default F14 Display Brightness Down binding.

## Device fingerprint

| Property | Observed value |
|---|---|
| Product | SayoDevice O2L V2 |
| Vendor ID | `0x8089` (32905) |
| Product ID | `0x000C` (12) |
| Serial | redacted for publication |
| USB location | redacted for publication |
| Vendor collection | usage page `0xFF00`, usage `0x01` |
| Configuration report | ID `0x02`, 63-byte payload area, 64 bytes including report ID |
| Alternate vendor collection | usage page `0xFF11`, usage `0x02`, report ID `0x21` |

The configuration interface belongs to the same composite descriptor as the keyboard collection. macOS consequently marks it `RequiresTCCAuthorization = Yes`; Input Monitoring must be granted to the app before IOKit will open it.

## Descriptor interpretation

The observed configuration descriptor begins:

```text
06 00 ff 09 01 a1 01 85 02 15 00 26 ff 00 75 08 95 3f 09 01 81 00 09 01 91 00 c0
```

This describes vendor usage page `0xFF00`, application usage `0x01`, report ID `0x02`, and symmetric 63-byte input/output reports. The rest of the descriptor adds report ID `0x21`, keyboard report `0x01`, mouse report `0x03`, and consumer-control report `0x04`.

## Packet framing

All configuration packets are zero-padded to 64 bytes:

```text
offset  size  meaning
0       1     report ID, always 0x02
1       1     command
2       1     payload length N
3       N     payload
3 + N   1     checksum
...           zero padding to 64 bytes
```

For outbound requests, the checksum is the wrapping 8-bit sum of `report ID + command + length + payload`. For example, the flash-save packet starts `02 04 02 72 96 10`.

Observed firmware `0x089A` does not use that additive rule for the response trailer. Its stable initialization response ends in `0x23` where the outbound sum would be `0x07`; button-map responses likewise use opaque trailers (`0x18` and analogous values). Sayobot's reference client validates the request checksum but intentionally does not validate the response trailer. Keyboard Studio therefore keeps strict outbound encoding and response framing/length validation while treating the firmware's trailing response byte as opaque.

## Recovered commands used by the app

| Command | Purpose | Payload used |
|---|---|---|
| `0x00` | initialize/query capabilities | current day, hour, minute, second |
| `0x04` | commit current configuration to flash | `72 96` |
| `0x06` | legacy button read/write fallback | mode, button, action and key data |
| `0x07` | legacy lighting on supporting firmware | pattern, LED number, type, event, command length, RGB, interval |
| `0x08` | device name read/write | read/write marker and null-terminated UTF-8 name |
| `0x0B` | one-key password slots | read/write marker, slot, and secret value |
| `0x0C` | one-key text slots | read/write marker, slot, mode, and UTF-16-style value bytes |
| `0x10` | Lighting v2 | pattern, LED number, effect mode, 19 effect/value bytes |
| `0x11` | Lighting v2 color tables | pattern, table number, table mode and color values |
| `0x16` | modern key-map read/write | 16-byte header plus five 6-byte layers |
| `0xF0` | device script bytecode | 16-bit address followed by up to 54 data bytes |
| `0xF1` | device script-slot metadata | read/write marker, slot number, and slot name/binding metadata |
| `0xFE` | configured USB identity | read returns little-endian VID and PID |

Modern key-map reads send `[0, buttonNumber]`. Writes preserve 14 opaque header bytes returned by the device and change only the read/write marker, button number, and decoded layer values. Each layer is:

```text
[mode, reserved, modifier, key1, key2, key3]
```

The app retains the legacy command because older Sayo firmware may not advertise or answer command `0x16`.

## Save and safety behavior

Reload never sends a write-mode key map or flash-commit command. Edits stay in memory until the user presses **Save to keyboard**. Save performs this ordered sequence:

1. Encode and send each complete button configuration.
2. Decode the response and verify that the returned button number matches.
3. Send `command 0x04` with the `72 96` guard bytes.
4. Reload the device state.

RGB Codex indication deliberately omits the flash-save command, avoiding repeated flash wear. Observed firmware `0x089A` advertises Lighting v2 command `0x10` instead of legacy command `0x07`. Reads use `[0, LED]`; writes use `[1, LED, mode, values...]`. Static writes change the documented first nine values while preserving ten firmware-specific trailing bytes returned by the device.

## Codex activity path

Keyboard Studio reads `~/.codex/sqlite/codex-thread-summaries-dev.db` using `/usr/bin/sqlite3 -readonly -json`. It selects recent `thread_id`, `summary`, `compact_summary`, and `updated_at` values from `thread_turn_summaries`. No Codex database writes and no network requests are made.

New timestamps can produce an in-app row and an opt-in UserNotifications alert. Version 0.3.0 also reads `task_started`, `task_complete`, and `turn_aborted` records from recently modified local rollout JSONL files. It scans backward only until the latest lifecycle record, caches stable files, and reads only appended bytes for active tasks. On firmware that advertises command `0x10`, LED 0 is blue while one or more tasks are active and LED 1 is red when a completed or interrupted task is waiting for acknowledgement. The pre-lamp Lighting v2 records are restored when the lamp clears. The physical O2L V2 has no text display, so task text cannot be rendered on the hardware itself.

## Recovered official configuration surfaces

The current official app and public client were used as protocol precedent, then every non-destructive record family was confirmed against the owned O2L. Command `0x11` returns exactly six palette records, each containing ten RGB colors plus preserved firmware-owned bytes. Command `0xF1` returns two script-name records. Command `0x0C` returns 16 one-key text records. Command `0x08` returns the mutable device name and `0xFE` returns configured VID/PID.

The installed application uses those confirmed bounds instead of probing one record past the end. A live version-0.4.0 trace showed successful TX/RX pairs for all startup reads and no `HID command rejected` event. Writes are scoped: text/password save touches only the selected slot; lighting, palette, name, key-map, and script saves verify an echo before the guarded flash commit. Backup import only stages decoded values.

## Device script boundary

The live capability list contains `0xF0` and `0xF1`. Sayobot's public client uses `0xF0` for chunked bytecode transfer and `0xF1` for named script-slot metadata. The official VM instruction set includes HID keyboard, mouse, and consumer input; delays and randomized timing; branches, loops, calls, arithmetic, bitwise operations, registers, globals, a stack, layer and LED control, memory allocation, and child threads. This bytecode runs on the keyboard. It cannot execute a macOS shell, AppleScript, Swift, or Python process. Keyboard Studio 0.4.0 exposes verified script image/name writes and safe templates; Codex actions remain Mac-side handlers triggered by F13/F16.

Firmware update, bootloader/recovery, device lock, and factory reset are intentionally not emitted as guessed raw commands. The UI identifies them as maintenance capabilities and links to the official firmware catalog. Enabling them requires a verified model-specific package or exact confirmed command semantics, a recoverable backup, and explicit user confirmation.

## Permission boundaries

- Launch performs read-only authorization-status checks and does not display a permission prompt.
- The app calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` only after the user clicks **Open Input Monitoring**. If approval is still needed, that action opens the exact Privacy & Security pane with a System Settings deep link. The access is used for the SayoDevice's composite HID configuration interface.
- F13/F16 use `RegisterEventHotKey`; the app does not install an `NSEvent` global key monitor, event tap, or Accessibility trust request. Each registered press creates a visible in-app history row and a structured unified-log event without observing unrelated keys.
- `UNUserNotificationCenter.requestAuthorization` is called only after **Enable macOS alerts**. A prior denial is represented as **Open Notification Settings**, because macOS will not present the authorization prompt again.
- No permission usage-description keys or private entitlements are added to the packaged app.

The first ad-hoc package used the default CDHash designated requirement. Rebuilding changed that hash, leaving System Settings with a checked authorization for the previous executable while TCC denied the new one. Packaging now supplies a stable local designated requirement based on the fixed bundle identifier. The stale `ListenEvent` record for `com.lucas.keyboardstudio` was reset once; no other application's permissions were changed. Because the menu-bar extra keeps the process alive after its window closes, the UI now provides an explicit delayed restart and a true Quit command.

## Verification

- `swift build`: passed for all library and executable products.
- `swift run protocol-check`: passed packet, strict request checksum, corruption-rejection, observed firmware-response, live/five-layer codecs, header preservation, official key/lighting catalogs, indexed records, script templates, backup round-trip, Codex Deck, F13/F16 hot-key mapping, and Codex lifecycle assertions.
- `swift run sayo-probe --codex-status`: reported one active task during live status-lamp development.
- Release package: version 0.4.0 build 7 built and ad-hoc signed with stable designated requirement `identifier "com.lucas.keyboardstudio"`; strict code-sign verification passed.
- SwiftUI runtime: launched successfully from the packaged `.app`.
- Codex feed: rendered 27 real local task summaries in the packaged app.
- HID live read: model `0x0002`, capability list, both button maps, two Lighting v2 records, six palettes, device name/identity, two script names, script image, and 16 text records decoded successfully from the installed application. The latest launch trace contained no rejected commands. The existing status lamp performed only verified volatile command-`0x10` writes and did not alter flash.

## Source correspondence

The packet framing, outbound checksum, initialization, save guard bytes, key-map layout, response-trailer behavior, record banks, scripts, and light structure were cross-checked against Sayobot's public `Sayo_CLI`, current official configurator, and live owned-device frames. The public manual documents the related HID scripting model. IOKit is used according to Apple's open/set-report/callback/run-loop APIs.

### F-001 Composite HID configuration and authorization boundary

- severity: info
- evidence_ids: E-001, E-002, E-003, E-004, E-006
- confidence: high
- location: local-connected-keyboard-2 vendor HID collection FF00:01
- status: validated

The device can be configured directly with vendor report `0x02`, but the shared keyboard collection causes macOS to require Input Monitoring. The application checks this gate explicitly, preserves unknown device bytes, and makes persistent writes user-initiated.

### P-001 Configuration call flow

- path_type: callflow
- evidence_ids: E-001, E-002, E-003, E-004

`Keyboard Studio → IOHIDCheckAccess → usage-filtered IOHIDManager → report 02 packet codec → command 22 write and response validation → command 04 guarded flash commit`
