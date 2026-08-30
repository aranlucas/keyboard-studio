# Keyboard Studio

Keyboard Studio is a native macOS SwiftUI configurator for the connected **SayoDevice O2L V2** two-key pad. It talks directly to the device's vendor HID collection, exposes the safely recovered features of SayoDevice's official configurator, and turns the pad into a live Codex status lamp. It is a real macOS app—not a wrapper around the web configurator.

## Open the app

Open `/Applications/Keyboard Studio.app`. The signed build artifact is also retained at [`dist/Keyboard Studio.app`](dist/Keyboard%20Studio.app).

The SayoDevice advertises keyboard input, so macOS protects it with Input Monitoring:

1. Click **Open Input Monitoring** in Keyboard Studio. This is the only action that requests the permission, and it opens the exact System Settings pane when approval is still needed.
2. Enable Keyboard Studio in **System Settings › Privacy & Security › Input Monitoring**.
3. Click **Restart Keyboard Studio**. Closing the window is not enough because the Codex Deck menu-bar remote keeps the application running.

The packaged app uses a stable local designated requirement, so rebuilding it no longer replaces its Input Monitoring identity. Version 0.4.1 uses the same `com.lucas.keyboardstudio` requirement as the previously approved build.

Keyboard Studio never requests Accessibility access and does not observe general keyboard input. Codex Deck registers only F13 and F16 as dedicated system hot keys. macOS notification access is separate and is requested only after you click **Enable macOS alerts**; if you previously denied it, the app links to Notification Settings instead of pretending macOS can show the prompt again.

Codex Activity does not require keyboard access. It reads the local Codex summary database in read-only mode and refreshes every 15 seconds.

## Official-feature parity

The native sidebar now provides:

- **Keyboard:** both buttons, every reported layer, all recovered action modes, keyboard chords, mouse and media actions, one-key text/passwords, script bindings, and momentary/toggle layers. Typed controls cover common actions; the four raw parameter bytes remain available for firmware-specific modes.
- **Lighting:** all 11 Lighting v2 effects, direct/palette/random color sources, speed, press/release behavior, hold timing, and six editable ten-color palettes.
- **Text & Passwords:** 16 one-key text slots and opt-in password loading. Save writes only the selected slot. Passwords are excluded from backups unless explicitly included.
- **Scripts:** both named script slots, the raw on-device VM image, and safe builders for tap, repeat-while-held, and LED scripts. Scripts execute on the keyboard; they do not run macOS shell commands.
- **Device:** name, USB identity, firmware/model metadata, and advertised command set.
- **Backup & Restore:** portable JSON backups of key maps, opaque bytes, lighting, palettes, text, scripts, and naming. Import stages changes for review; it does not immediately write them.

Firmware update, recovery/bootloader, device lock, and factory reset are shown as detected maintenance capabilities but remain guarded. Keyboard Studio will not guess destructive command payloads or offer a firmware downgrade for model `0x0002`.

## Customize the pad

- Choose one of the device-reported layers.
- Set a primary key, optional second and third HID key codes, and Control/Shift/Option/Command modifiers for each button.
- Use **Copy / Paste** or **Codex triggers · F13 / F16** as starting profiles.
- Changes remain staged until **Save to keyboard** is pressed.
- Save writes both mappings, verifies the device response, and only then sends the flash-commit command.

The pad has RGB LEDs but no text display. Codex notification text therefore lives in the Mac app. The status lamp reads local Codex rollout lifecycle events: Button 1 is blue while any task is running, Button 2 is red when a completed or interrupted task needs attention, and F16 acknowledges the result. Lighting changes are volatile, are never committed to keyboard flash, and the app restores the lighting record it found before activating the lamp.

## Codex Deck

The **Codex Deck** profile gives the pad a purpose-built first layer:

- Button 1 sends F13 and opens Codex from any app.
- Button 2 sends F16, marks current Codex updates as caught up, and clears the attention lamp while leaving the working lamp accurate.
- A menu-bar remote keeps both actions and the unread count available when the main window is closed.
- Installing the profile preserves all other layers and the device's opaque configuration bytes.

## Device scripts

The observed firmware advertises command `0xF0` for script bytecode and `0xF1` for its two script slots. Sayo's on-device VM can emit keyboard, mouse, and media input; use fixed or randomized delays; branch and loop; perform register, stack, arithmetic, and bitwise operations; switch layers; and control RGB. It cannot run macOS shell commands, AppleScript, Swift, or Python. Keyboard Studio can read, edit, write, and verify the bytecode image, and its templates always release keys and terminate. See the [official device script documentation](https://github.com/Sayobot/SayoDevice_manual/blob/main/docs/en/docs/std/web_hid/script.md).

## Build and verify

Requires macOS 14 or newer and Swift 6 Command Line Tools.

```sh
swift build
swift run protocol-check
swift run sayo-probe
swift run sayo-probe --codex-status
swift run sayo-probe --read-device-name
swift run sayo-probe --read-device-identity
swift run sayo-probe --read-indexed 11 6
swift run sayo-probe --read-named-slots F1 2
swift run sayo-probe --read-script-image
./scripts/package_app.sh
codesign --verify --deep --strict --verbose=2 "dist/Keyboard Studio.app"
```

`sayo-probe` is read-only unless an explicit `--set-*` or `--install-codex-deck` option is supplied. Its default mode prints the connected identity, firmware metadata, supported commands, and both button maps as JSON after Input Monitoring is granted. `--codex-status` does not open the keyboard; it reports the local active-task count and latest completion/interruption timestamps.

## Architecture

- `CHIDBridge`: minimal C bridge around IOKit HID discovery, permissions, reports, and callbacks.
- `KeyboardCore`: packet framing, strict outbound checksums, firmware-response trailer handling, key/lighting/palette/text/password/script codecs, backup model, device service, and cached read-only Codex summary/lifecycle services.
- `KeyboardStudio`: SwiftUI macOS app.
- `sayo-probe`: reproducible read-only device probe.
- `protocol-check`: framework-independent protocol assertions for this machine's Command Line Tools installation.

The reverse-engineering record is in [`work/keyboard-two/report/reverse-engineering.md`](work/keyboard-two/report/reverse-engineering.md).
