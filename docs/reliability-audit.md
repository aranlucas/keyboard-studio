# Correctness and reliability audit — 2026-11-06

Baseline: remote default `e676e65555366958fa08e55d20d6681771e37e56` (merged untangle pass). Clean isolated worktree. This is a behavior audit; public APIs and intended behavior remain intact. Tests/builds run in CI only.

## Inventory and trust boundaries

- SwiftPM products: KeyboardCore, protocol-check, macOS KeyboardStudio and sayo-probe; C IOKit HID bridge. No JavaScript/TypeScript project or runtime target exists, so tester-army/e2e and its web/mobile engines do not apply. Existing Swift Testing and protocol assertions are the faithful offline regression harness.
- Configuration journey: discover and select a serial/location-bound device, stage edits in SwiftUI, validate immutable save plan, restore temporary lamps, write/verify records, flash, reapply lamps. Actor serializes complete commits without suspension. Failed writes gate retries behind refresh; flash uncertainty and post-flash lamp errors are distinguished.
- Persistence: device flash, JSON backups (identity/capability/shape validation and bounded imports; opt-in password export), UserDefaults Hyperdeck profiles, local Codex SQLite summaries and JSONL rollouts. No network auth, multi-tenant service or production database writes.
- External actions: dedicated Carbon hotkeys and App Intents resolve configured recipes; recipe deep links are disabled; executable launch uses argument arrays. Clipboard collection is opt-in and bounded in memory. Maintenance/firmware/reset operations are guarded and unimplemented.
- Reviewed surfaces: protocol framing/record codecs, device service and backup validation, C bridge device selection/timeouts/cleanup, application loading/saving/status flows, gesture state machine, Hyperdeck actions/preferences, activity lifecycle scanner/cache, CLI tools and packaging/CI.

## Findings recorded before implementation

1. **High confidence, medium impact — lifecycle cache loses an event split across polls.** `CodexActivityService.lastLifecycleEvent` reads appended bytes from the previous file size, then advances the cached size even if those bytes end in an incomplete JSON record. When a task completion is appended in two writes, neither fragment decodes; subsequent polls retain the old started event indefinitely until another event arrives. Expected: once the completed line is present, attention replaces active status. Fix the append boundary, with a split-completion file regression.
2. **High confidence, medium impact — SQLite output can deadlock polling.** `CodexActivityService.recent` waits for sqlite3 to exit before draining its stdout pipe. A legitimate long summary or several summaries can exceed pipe capacity; sqlite3 waits for a reader while the parent waits for termination. Expected: bounded row query returns complete summaries. Use Foundation file output instead of undrained pipes and exercise a large fixture in CI.
3. **High confidence, medium impact — device-name decoder strips UTF-16 content bytes.** `SayoDeviceService.readDeviceName` drops every leading zero byte instead of just the response's operation byte (the existing scripted transport emits `[0] + UTF16LE`). A name beginning with U+0100 has a zero low byte; dropping it misaligns the entire name and makes commit verification fail after changing volatile device state. Expected: exact UTF-16LE readback including such characters and empty names. Remove only the operation byte, with commit regressions.

## Rejected hypotheses and limits

- Actor reentrancy during flash: rejected; commit has no suspension points and existing gated transport tests protect ordering.
- Device swap redirects writes: rejected; selection identity is passed through every transaction and C bridge matches serial/location. Physical firmware/USB failures remain outside offline coverage.
- Backup silently writes hardware: rejected; import stages validated data only. Export intentionally captures staged values per README.
- Unsupported raw maintenance commands: rejected; guarded rather than guessed firmware semantics.
- CI `parallel` syntax: not reported as broken; current default CI run 42256124332 succeeded. Preserve existing meaningful gates.
- Live HID discovery, Input Monitoring UI, physical flash persistence, third-party application behavior and actual hardware timing cannot be established by fixture tests. No physical writes or production resources used.

## Validation plan

Keep existing macOS test/release/protocol/static-analysis CI. Add deterministic regressions to the existing runner. A separate CI job applies the new test files to the audited baseline and expects the named defect regressions to fail; the fixed head must pass the full existing gate. Independent review will challenge findings and changes. CI links/results and review outcome will be recorded after execution.

## Additional findings from independent review (before their fixes)

4. **High confidence, high impact — staged secrets/configuration survive device refresh.** AppModel starts extended loading from the previous configuration and retains `secretsAreLoaded` and password slots. Load passwords from pad A, swap to B and refresh: export can label A's secrets as B's and Save Passwords can write them to B. An early extended-read failure likewise retains A's settings. Explicit refresh must discard old extended state and secret opt-ins before reading another snapshot; failed/unsupported reads must leave fresh empty state, never the previous device's data.
5. **High confidence, medium impact — probe hardware options never select a device.** SayoProbe dispatches all optional reads/writes before `readSnapshot`, although transactions require a selection. `--read-lighting-v2` even swallows the error and prints `[]`. Select once after the offline Codex-status branch and before hardware dispatch. Fixture core tests protect the selection requirement; CI compiles the CLI. Live CLI option journeys require the physical pad and are not claimed as validated offline.

Implementation note: the SQLite fixture also covers an empty table. sqlite3 emits empty stdout rather than an empty JSON array; the old decoder reports this normal state as an error. `recent()` now returns an empty collection for that case. Query output/diagnostics use Foundation FileManager/FileHandle in a mode-0700 temporary directory with mode-0600 files, removed on exit. No dependency or custom script was needed. Lifecycle growth reuses the existing backward scanner instead of maintaining a second parser for partial lines.

6. **High confidence, medium impact — both-key hold fires after one key has been released.** The gesture recognizer retains the chord until final release but also schedules its hold deadline without checking that both keys are still held. L-down at 0, R-down at .04, L-up at .1, flush at 1.5 emits bothHold (default: reset focus). A chord now loses hold eligibility on the first release while retaining its existing bothTap emission on final release. New deterministic gesture regression protects this distinction.

The app now has a macOS-only Swift Testing target. Its denied-access transport exercises an actual failed refresh after seeding previous-device settings and secret consent; no HID, hotkey registration or app startup tasks run. An internal initializer seam preserves default app startup behavior.

7. **High confidence, medium impact — palette label overflows on imported byte 255.** LightingCard adds 1 to UInt8 to display a one-based palette. Backup/raw lighting preserves arbitrary firmware bytes, so a structurally valid imported record with value[8] == 255 crashes rendering. Convert to Int for presentation arithmetic; existing stored byte and editable control range remain unchanged. This one-line presentation fix is statically verified; no implementation-mirroring test was added.

## Review and CI tracking

Independent reviewer approved `fce7eb7` by static inspection after challenging findings and identifying refresh isolation, probe selection, continuous chord holds, and palette overflow. No local tests/builds ran. PR: https://github.com/aranlucas/keyboard-studio/pull/14. CI run 42301766319 baseline job was rejected before execution because repository policy requires full-SHA action pins. The artifact action is now pinned to its published v4 commit; replacement CI is pending. No passing test claim or merge yet.

CI follow-up: run 42302023176 exposed a Swift 6 isolation error in the new SQLite fixture: its synchronous setup helper accessed the actor-isolated `databaseURL`. The async test now captures that URL with `await` before calling the helper. Production behavior is unchanged; replacement CI must validate compilation and all regressions.
