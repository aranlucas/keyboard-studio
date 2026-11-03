# SayoDevice O2L V2 protocol notes

These observations come from the locally owned O2L V2 inspected on 2026-08-29
and comparison with [Sayobot Sayo_CLI](https://github.com/Sayobot/Sayo_CLI), the
[official configurator](https://app.sayodevice.com/) and
[SayoDevice manual](https://github.com/Sayobot/SayoDevice_manual). They describe
that device and firmware, not certification of other models or later firmware.
The investigation covered local HID reads and reviewed configuration writes;
it excluded denial of service, phishing and unrestricted exfiltration. It does
not authorize future hardware or security operations. Physical serial and USB
location identifiers are omitted from the published observations.

## Device and descriptor

| Property | Observed value |
| --- | --- |
| Product | SayoDevice O2L V2 |
| VID:PID | `0x8089:0x000C` |
| Firmware / model | `0x089A` / `0x0002` |
| Configuration collection | usage page `0xFF00`, usage `0x01`, report ID `0x02` |
| Configuration report | 63 data bytes, 64 bytes including report ID |
| Alternate vendor collection | usage page `0xFF11`, usage `0x02`, report ID `0x21` |

The configuration descriptor begins:

```text
06 00 ff 09 01 a1 01 85 02 15 00 26 ff 00 75 08 95 3f 09 01 81 00 09 01 91 00 c0
```

The remaining composite descriptor includes keyboard report `0x01`, mouse
report `0x03` and consumer-control report `0x04`. IOKit marked the device
`RequiresTCCAuthorization = Yes` despite the app opening only vendor reports.
This is why configuration access requires Input Monitoring.

## Firmware quirks to preserve

### Request checksum and response trailer

Requests use a wrapping 8-bit additive checksum over report ID, command, length
and payload. The flash guard request begins `02 04 02 72 96 10`.
Repeated live initialization responses instead returned this stable frame:

```text
02 00 15 08 9A 00 02 F0 32 F0 00 04 06 08 0B 0C 10 11 16 F0 F1 FC FE FF 23
```

Its trailer is `0x23`, while the request checksum rule would produce `0x07`.
Button-map replies also had opaque trailers. The reference client did not
validate response trailers. Keep strict request encoding and response
report-ID/length checks without applying the outbound checksum rule to replies.
[SayoPacket](../../../Sources/KeyboardCore/SayoProtocol.swift) and the captured
frame assertions in [protocol-check](../../../Sources/ProtocolCheck/main.swift)
encode this distinction.

### Key maps and lighting

Live command `0x16` (decimal 22) reads decoded two layers for each of two buttons;
keyboard mappings used mode `0`, not mode `1`. Writes preserve the 14 opaque
header bytes after the read/write marker and button number. Legacy command
`0x06` remains a fallback for firmware without a usable modern map.

The observed capability list omits legacy lighting command `0x07` and advertises
Lighting v2 `0x10` and color tables `0x11`. Both LED records contained 19 value
bytes in mode 4. Static writes changed the first nine values and preserved the
ten-byte opaque suffix; responses echoed the writes. The owner visually
confirmed LED 0 red and LED 1 blue. Those tests sent no flash commit.

The confirmed record banks were two LED records, six palettes of ten RGB
entries, two script-name slots and 16 one-key text slots. These observations
explain the app's bounded discovery; do not infer more slots by probing beyond
the confirmed records. The device-name codec uses UTF-16 little-endian units;
see [SayoDeviceService](../../../Sources/KeyboardCore/SayoDeviceService.swift)
for current transfer layouts and write verification.

Codex Deck uses F13 (`0x68`) and F16 (`0x6B`). F16 replaced F14 because the latter
triggered macOS Display Brightness Down. Installing the profile preserved the
other layer and opaque headers, then fresh reads confirmed the new mappings.

## Save and script boundaries

See [save, backup and recovery](../../../README.md#save-backup-and-recovery)
for the current user procedure. The [configuration actor](../../../Sources/KeyboardCore/SayoDeviceService.swift)
and [commit regression tests](../../../Tests/KeyboardCoreTests/SayoConfigurationCommitTests.swift)
define validation, identity binding, partial-write recovery and lamp handling.
Codex status lighting is volatile: restore the pre-lamp records before a flash
commit so temporary status colors do not become persistent configuration.

Commands `0xF0` and `0xF1` are device bytecode transfer and script-slot metadata.
The documented VM supports HID input, timing, control flow, arithmetic, memory,
layers and lighting. Bytecode runs on the keyboard; it does not directly launch
macOS shell, AppleScript, Swift or Python processes. It can emit host input, so
inspect imported scripts and macros before saving. Mac-side Codex actions are
registered F13/F16 handlers. Firmware update, recovery, lock and reset must not
be implemented by guessing raw command semantics.

Codex activity is local and read-only: it queries
`~/.codex/sqlite/codex-thread-summaries-dev.db` with `sqlite3 -readonly -json`
and reads recent rollout JSONL files under `~/.codex/sessions`. The
[activity service](../../../Sources/KeyboardCore/CodexActivityService.swift)
makes no network requests or Codex data writes. The O2L has no text display;
activity text stays in the app and menu bar.

## Permission identity and recovery

Launch checks access status without prompting. Device access is requested only
from **Open Input Monitoring**. F13/F16 use
registered Carbon hot keys, without an arbitrary-key monitor, event tap or
Accessibility trust request. Notifications are separately opt-in; after denial,
use **Open Notification Settings** because another prompt will not be shown.

The first ad-hoc package used a CDHash designated requirement. Rebuilding changed
that hash: System Settings showed a checked grant while TCC denied the new
executable. [Packaging](../../../scripts/package_app.sh) now uses the stable
requirement `identifier "com.lucas.keyboardstudio"`.

If a packaged rebuild still has this checked-but-denied symptom, quit Keyboard
Studio completely, reset only its stale Input Monitoring grant, reopen the
packaged app, click **Open Input Monitoring**, enable the new entry and restart
the app. The app-specific reset used during the original diagnosis was:

```bash
tccutil reset ListenEvent com.lucas.keyboardstudio
```

This removes the app's existing grant and requires reapproval. Do not reset
other applications' permissions. Restart is available only from a packaged
`.app`; closing its window alone does not quit the menu-bar process.

For HID diagnosis, inspect the app's structured transaction logs:

```bash
/usr/bin/log show --last 2m --predicate 'subsystem == "com.lucas.keyboardstudio" AND category == "SayoHID"'
```

Historical live checks establish the observations above, not a current build or
hardware guarantee. Offline tests cannot certify HID access, visual LED behavior
or flash persistence on a physical pad.
