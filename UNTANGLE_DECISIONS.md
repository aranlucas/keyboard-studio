# Untangle decision log

## Scope and baseline

- Bound worktree: `/home/lucas/.t3/worktrees/keyboard-studio/refactor-untangle-codebase-20261106`.
- Branch: `refactor/untangle-codebase-20261106`; initial HEAD `7153298`; initial worktree clean.
- Exact skill fetched and read from https://raw.githubusercontent.com/caldoai/skills/main/skills/untangle-codebase/SKILL.md before inspection/edits. Both Comments and Tests selected by user.
- Repository AGENTS.md applies throughout; use Foundation/SwiftUI and Swift Testing, no dependencies or scripts needed.
- Initial validation: `swift --version` fails (`swift: command not found`). This is an environment limitation, not a failing repository test. Checking a Swift container for portable checks; macOS UI/IOKit cannot run here.

## Inventory before implementation

All tracked source areas reviewed by primary agent and independent inventory reviewers:
- Package.swift: portable KeyboardCore + ProtocolCheck + Swift Testing; macOS-only CHIDBridge, SwiftUI app and SayoProbe.
- Core: framing/button maps/records/backups/catalogs/deck profile in SayoProtocol; synchronous actor-owned device commits, identity-bound transport; Codex SQLite/rollout activity; pure Hyperdeck gestures/configuration.
- App: AppModel bridges device edits, Codex activity and lamp; HyperdeckController executes recipes and owns focus/clipboard runtime; Carbon hotkeys/App Intents; SwiftUI screens/settings/menu.
- Bridge/probe: IOKit resource and identity ownership; explicit command-line hardware operations.
- Tests: protocol/backup/gesture contracts, scripted transport commits and lamp safety, rollout replacement/append cache behavior. ProtocolCheck additionally preserves captured firmware fixtures.
- Packaging/CI/docs: native tool invocations, stable ad-hoc signing requirement, protocol evidence and roadmap; no structural rewrite warranted.

## Design and justified implementation list

1. Give wire records ownership of encoding/decoding and their limits.
   - Hidden link: Lighting v2 lives inside service; validation reconstructs the packet separately from actual writes.
   - Hidden link: script/password truncation/padding repeated in writes and commit verification.
   - Needless link: backup validation chooses raw byte shape from diagnostic `name == "password"`.
2. Name the observed hardware bank bounds in core and use them in backup validation and app discovery.
   - Hidden link: two lights/six palettes/two script names/sixteen strings duplicated across layers.
3. Split SayoProtocol's independent domains into framing, button mapping, records, backups, catalogs and Codex Deck files without changing public APIs or module dependencies.
   - Needless link: unrelated changes require reading a single mixed protocol file.
4. Simplify commit internals: single verified button write, direct transport discovery; remove unused error case and unused static-lighting convenience method after caller search.
   - Surplus: array writer used only with singleton arrays; discovery pass-through; dead APIs.
   - Retain probe compatibility save entry points: these encode useful externally callable behavior and have existing regression coverage.
5. Centralize app preference keys/defaults and shared navigation contract; retain Hyperdeck's injected defaults for writes.
   - Hidden links: lamp key/default and refresh interval duplicated across AppModel/settings/screens; model navigation depends on view-owned enum.
   - Ownership error: Hyperdeck loads injected preferences but saves to global standard store.
6. Remove implementation-restating comments, then review tests last.
   - Existing tests protect real regressions; do not delete meaningful fixtures or hardware assertions merely because runner coverage overlaps.

## Required special cases retained

Opaque firmware response trailers; legacy map fallback; opaque button and light suffix bytes; atomic synchronous commits; identity/refresh guards; restore lamp before flash and distinguish post-flash lamp failure; serial plus USB location binding; script terminators/chunk bounds/short-read termination; distinct script/password formats; optional secret backup fields; platform metadata differences; inode-aware rollout cache; Carbon hotkeys; executable restrictions; permission-stable signing. These follow documented hardware, platform or safety contracts.

## Verification and review (updated during work)

No source edits preceded this inventory/design record. Independent reviewers found the above worthwhile changes and no reason to redesign the C bridge, rollout cache or gesture state machine.

### Implementation and review disposition

- Completed items 1–5: record-owned lighting/slot codecs; typed slot formats remove diagnostic-driven behavior; shared O2L bank bounds; protocol domains split into focused files; single-button commit verification/direct discovery; shared preferences/navigation and consistent injected preference-store persistence.
- Moved the text-slot codec from AppModel onto SayoIndexedRecord, preserving pair decoding, 28-byte input bound, 56-byte data region and opaque suffix. Shared existing Codex Deck HID constants in profile staging. Hyperdeck schema format now belongs to its configuration model.
- Preserved atomic lighting-load assignment: a failed second read must not publish half a bank.
- Removed redundant operational comments. Reviewed tests last and retained all existing tests: each protects a credible protocol, identity, cache, gesture or commit regression. Added two focused text-record tests for mixed pairs/termination and bounded edits/suffix preservation.
- Independent final whole-repository review found no remaining behavior regression or worthwhile redesign. Requested missing text-codec coverage (added), final validation/log completion (recorded here), and macOS CI (PR gate).
- Optional repeated keyboard-mode classifications remain local to ButtonMappingCard: they describe its controls and summary within one view; expanding the catalog API for these three checks is not justified by a cross-domain change requirement.
- Final local `swift test -j 2` in `swift:6.0` container: **36 tests passed**. Earlier pre-addition run: all 34 existing tests passed. `git diff --check` passed. No repository baseline failure or introduced test failure observed; absence of host Swift was resolved for portable checks by the container.
- macOS SwiftUI/AppKit/IOKit build and C static analysis require the repository's macOS CI. Physical HID interactions/flash are not exercised by offline checks.
- Before the CI-only user constraint, release protocol-check completed successfully (build 109.12s; all protocol assertions PASS). On receipt of that constraint, process inspection confirmed no owned local Swift/test/build process remained. Further behavioral/build validation runs only in CI.
