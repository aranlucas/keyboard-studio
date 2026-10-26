# Keyboard Studio feature roadmap

Updated 2026-10-26. Proposed work after Digits/MCP priorities. The supported
hardware remains the SayoDevice O2L V2; broader device support is not assumed.

## Starting point

Baseline `e0efbd947a0aacfa7101ced4adcb1d5f87ab470d`: the [app](README.md)
already edits layers/macros/lighting, backs up configuration, supports Hyperdeck
gestures and displays Codex attention through the pad and menu bar. Saves
validate an edit plan and device identity; a partial volatile write requires
Refresh, not an assumed firmware rollback.

## Ordered releases

1. **Set up a useful pad in one session.** Guide a new owner through device
   recognition, required permission, reading the current configuration, trying
   a supported preset and reviewing the exact changes before saving.
   Acceptance: an unsupported or disconnected device cannot appear ready;
   declining permission is recoverable; the first save preserves an exportable
   starting configuration. Tests with a simulated transport do not certify
   physical HID behavior.
2. **Switch between named task configurations.** Extend the existing layer and
   gesture editors with named coding, navigation or media configurations and a
   preview of differences. Acceptance: device identity is rechecked before a
   write; macro contents are inspectable and excluded from telemetry; importing
   a profile does not execute scripts or immediately flash the device.
3. **Make Codex attention understandable at a glance.** Explain the active
   thread and why it needs attention, with a deliberate action to open the
   correct place. Acceptance: stale/disconnected activity looks different from
   current work; an old completion cannot clear a newer attention state; the
   user can disable the indication without losing device configuration.
4. **Recover from a failed save without guessing.** Offer a clear guided
   Refresh, comparison with the last confirmed configuration and a reviewed
   retry. Acceptance: distinguish flash success from a subsequent lamp failure,
   retain user edits for comparison, and never promise rollback unsupported by
   the firmware. Build on the existing configuration actor.

## First slice and evaluation

Start with onboarding on one physical supported pad. Observe time to the first
useful shortcut, permission confusion, wrong-target attempts and recovery from
a deliberate disconnect. Then assess whether the owner uses the configuration
in a second coding session. No claim of productivity gain follows from a passing
protocol test alone.

Use SwiftPM and existing Swift Testing coverage for edit plans and state
transitions. Hardware validation is a separate release gate; do not flash a
device as part of documentation or unattended CI work. Defer notarized public
distribution until the supported-device journey is reliable and wanted.
