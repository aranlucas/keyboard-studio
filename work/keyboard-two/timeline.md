# Timeline (append-only)

## 2026-08-29T15:58:38-07:00 | lead | init
- action: case-init
- command_or_ref: skills/scripts/case-init.sh
- result_summary: case directory created; scope ready_for_act=true
- artifacts: [scope.md, workitems.md]
- evidence_ids: []
- decision_delta: [case_initialized]
- carry_forward_refs: [scope.md]
- next: open PRIMARY SKILL.md and ACT within scope

## 2026-08-29T16:02:00-07:00 | lead | hardware reconnaissance
- action: enumerated local HID and USB properties; parsed report descriptor
- command_or_ref: hidutil, ioreg, system_profiler
- result_summary: identified SayoDevice O2L V2 and its FF00:01 report-02 configuration collection
- artifacts: [evidence/E-001.md]
- evidence_ids: [E-001]
- decision_delta: [protocol-reverse-confirmed]
- carry_forward_refs: [scope.md]
- next: recover application framing and commands

## 2026-08-29T16:06:00-07:00 | lead | protocol recovery
- action: cross-checked the descriptor against public official Sayobot source
- command_or_ref: Sayobot/Sayo_CLI o2_protocol.cpp
- result_summary: recovered framing, checksum, init, key-map, light, and guarded flash-save commands
- artifacts: [evidence/E-002.md, report/reverse-engineering.md]
- evidence_ids: [E-002]
- decision_delta: [modern-key-map-command-22, legacy-fallback-command-6]
- carry_forward_refs: [evidence/E-001.md]
- next: implement a native configurator

## 2026-08-29T16:15:00-07:00 | lead | implementation
- action: implemented IOKit bridge, Swift protocol library, SwiftUI app, Codex activity feed, probe, and protocol checks
- command_or_ref: swift build; swift run protocol-check
- result_summary: all products built and 12 protocol assertions passed
- artifacts: [evidence/E-003.md]
- evidence_ids: [E-003]
- decision_delta: [writes-user-initiated-only, verified-before-flash-commit]
- carry_forward_refs: [report/reverse-engineering.md]
- next: package and inspect runtime

## 2026-08-29T16:22:00-07:00 | lead | runtime verification
- action: packaged, signed, launched, and visually inspected the SwiftUI app
- command_or_ref: scripts/package_app.sh; codesign --verify; CGWindow capture
- result_summary: Codex feed rendered 27 local task summaries; HID path exposed expected Input Monitoring gate
- artifacts: [evidence/E-004.md, ../../dist/Keyboard Studio.app]
- evidence_ids: [E-004]
- decision_delta: [explicit-keyboard-access-flow]
- carry_forward_refs: [report/reverse-engineering.md]
- next: user grants Input Monitoring and saves selected mappings

## 2026-08-29T17:05:00-07:00 | lead | Codex Deck and permission hardening
- action: implemented the F13/F14 Codex Deck profile, menu-bar remote, unread acknowledgement, RGB alert, and minimal permission flow
- command_or_ref: swift build; swift run protocol-check; scripts/package_app.sh; codesign; nm; System Settings deep link
- result_summary: 21 assertions passed; version 0.2.0 was signed; F13/F14 use registered hot keys without Accessibility; Input Monitoring and notification settings open only from explicit controls
- artifacts: [evidence/E-005.md, ../../dist/Keyboard Studio.app]
- evidence_ids: [E-005]
- decision_delta: [registered-hotkeys-not-global-monitor, direct-input-monitoring-pane, notification-denial-settings-link]
- carry_forward_refs: [report/reverse-engineering.md]
- next: user enables Keyboard Studio in Input Monitoring and installs Codex Deck to Layer 1

## 2026-08-29T17:25:00-07:00 | lead | TCC identity repair
- action: diagnosed checked-but-denied Input Monitoring state and repaired the package identity and restart UX
- command_or_ref: codesign -d -r-; security find-identity; tccutil reset ListenEvent com.lucas.keyboardstudio
- result_summary: prior ad-hoc build used a CDHash designated requirement that changed after rebuilding; package now uses a stable identifier requirement, stale app-only ListenEvent approval was reset, and the UI exposes automatic refresh, delayed restart, and true quit actions
- artifacts: [evidence/E-005.md, ../../dist/Keyboard Studio.app]
- evidence_ids: [E-005]
- decision_delta: [stable-local-designated-requirement, explicit-restart, menu-bar-quit]
- carry_forward_refs: [report/reverse-engineering.md]
- next: user clicks Open Input Monitoring once, enables the newly registered stable app entry, then clicks Restart Keyboard Studio

## 2026-08-29T17:45:00-07:00 | lead | live firmware response correction
- action: captured repeated live HID frames, compared with Sayobot's reference client, corrected response-trailer and keyboard-mode semantics, and installed the repaired build
- command_or_ref: unified log SayoHID trace; swift run protocol-check; scripts/package_app.sh; ditto to /Applications; codesign --verify
- result_summary: firmware 0x089A uses an opaque response trailer and mode 0 for keyboard maps; both two-layer button maps now decode, 29 assertions pass, and installed version 0.2.1 launches without decode errors
- artifacts: [evidence/E-006.md, /Applications/Keyboard Studio.app]
- evidence_ids: [E-006]
- decision_delta: [strict-request-checksum, opaque-response-trailer, keyboard-mode-zero, exact-write-echo-before-commit]
- carry_forward_refs: [report/reverse-engineering.md]
- next: user may install Codex Deck from the verified live device screen

## 2026-08-29T17:26:30-07:00 | lead | hot-key and capability correction
- action: replaced the macOS-reserved F14 acknowledgement with F16, gated RGB on the live capability list, added visible press logs and structured HID transaction logs, and installed the profile and app
- command_or_ref: swift run protocol-check; swift run sayo-probe --install-codex-deck; scripts/package_app.sh; ditto to /Applications; codesign --verify; unified log SayoHID trace
- result_summary: firmware 0x089A does not advertise command 7; the app no longer sends it, Button 2 now reads back as HID F16 (0x6B), Button 1 remains F13 (0x68), 29 assertions pass, and installed version 0.2.2 logs each HID request/response
- artifacts: [evidence/E-007.md, /Applications/Keyboard Studio.app]
- evidence_ids: [E-007]
- decision_delta: [avoid-macos-f14-display-binding, capability-gated-lighting, visible-press-history, structured-hid-logging]
- carry_forward_refs: [report/reverse-engineering.md]
- next: press both physical buttons and confirm the in-app Recent key presses rows

## 2026-08-29T19:49:02-07:00 | lead | Lighting v2 recovery and visual validation
- action: matched advertised commands 0x10 and 0x11 to Sayobot's Lighting v2 API, captured both live 19-byte LED records, tested volatile static writes, and integrated the confirmed path into Keyboard Studio
- command_or_ref: swift run sayo-probe --read-lighting-v2; swift run sayo-probe --set-static-lighting-v2; swift run protocol-check; user visual confirmation
- result_summary: both records accepted and echoed static mode; LED 0 visibly became red and LED 1 blue; the app now uses command 0x10, preserves ten opaque trailing values, and never sends a flash commit for RGB
- artifacts: [evidence/E-008.md, /Applications/Keyboard Studio.app]
- evidence_ids: [E-008]
- decision_delta: [lighting-v2-command-0x10, preserve-opaque-lighting-tail, volatile-rgb-only]
- carry_forward_refs: [report/reverse-engineering.md]
- next: package version 0.2.3 and verify purple preview and black clear through the app

## 2026-08-29T20:05:34-07:00 | lead | script boundary and Codex status lamp
- action: mapped the advertised script commands against official source and replaced summary-only RGB alerts with a cached local Codex lifecycle reader and two-channel lamp
- command_or_ref: Sayobot script manual; Sayobot/Sayo_CLI o2_protocol.cpp; swift run protocol-check; swift run sayo-probe --codex-status
- result_summary: commands 0xF0/0xF1 map to device bytecode and script-slot metadata; the live Codex reader reported one active task; installed readback showed Button 1 at RGB 0,104,255 and Button 2 off with no flash commit, while the original mode-4 animation records are retained for clear/disable restoration
- artifacts: [evidence/E-009.md, evidence/E-010.md, ../../dist/Keyboard Studio.app]
- evidence_ids: [E-009, E-010]
- decision_delta: [device-vm-not-host-script, rollout-lifecycle-source, two-channel-status-lamp, restore-prior-lighting]
- carry_forward_refs: [report/reverse-engineering.md]
- next: user confirms the physical blue working lamp; after this task completes the app should transition to red attention within the configured polling interval

## 2026-08-29T20:35:09-07:00 | lead | native official-feature parity
- action: recovered current official configurator surfaces, implemented native SwiftUI editors and codecs, bounded discovery from live records, packaged, installed, and traced the release
- command_or_ref: app.sayodevice.com; Sayobot/Sayo_CLI; swift build; swift run protocol-check; scripts/package_app.sh; codesign --verify; unified log SayoHID trace
- result_summary: version 0.4.0 build 7 exposes key action modes, 11 Lighting v2 effects, six ten-color palettes, 16 text slots, opt-in password slots, two script names and script bytecode, device name/identity, and staged JSON backup/restore; live startup completed without a rejected command
- artifacts: [evidence/E-011.md, ../../dist/Keyboard Studio.app, /Applications/Keyboard Studio.app]
- evidence_ids: [E-011]
- decision_delta: [native-not-web-wrapper, selected-slot-writes, bounded-record-discovery, destructive-maintenance-gated]
- carry_forward_refs: [report/reverse-engineering.md]
- next: user customizes desired mappings, lighting, macros, or scripts and saves the reviewed page
