# Work Items

| ID | title | role | targets | surface | status | evidence | notes |
|----|-------|------|---------|---------|--------|----------|-------|
| WI-001 | Establish scope and auth | lead | case | process | completed | scope.md | Own-system scope confirmed |
| WI-002 | Fingerprint second keyboard and HID descriptor | lead | local-connected-keyboard-2 | hardware | completed | E-001 | SayoDevice O2L V2, composite HID |
| WI-003 | Recover configuration framing and commands | lead | local-connected-keyboard-2 | protocol | completed | E-002 | Cross-checked with official public source |
| WI-004 | Implement and validate SwiftUI configurator | lead | local application | macOS | completed | E-003 | Build, protocol assertions, signed app |
| WI-005 | Integrate and inspect Codex activity | lead | local Codex database | macOS | completed | E-004 | Read-only feed, notifications, RGB option |
| WI-006 | Add Codex Deck and minimize permission scope | lead | local application and keyboard | macOS | completed | E-005 | Dedicated hot keys, menu bar remote, direct settings links |
| WI-007 | Correct firmware 0x089A response decoding | lead | SayoDevice O2L V2 | protocol | completed | E-006 | Opaque response trailer and mode-0 keyboard mappings validated live |
| WI-008 | Remove reserved-key and unsupported-lighting failures | lead | local application and keyboard | macOS | completed | E-007 | F16 acknowledgement, capability-gated RGB, press and transaction logs |
| WI-009 | Recover and integrate Lighting v2 | lead | local application and keyboard | protocol and macOS | completed | E-008 | Command 0x10 static RGB visually confirmed; opaque tail preserved |
| WI-010 | Identify the device script VM boundary | lead | SayoDevice O2L V2 and official source | protocol | completed | E-009 | Commands 0xF0/0xF1 advertised; VM capabilities documented; no write sent |
| WI-011 | Implement a live Codex status lamp | lead | local Codex rollouts and keyboard RGB | macOS | completed | E-010 | Cached lifecycle reader; blue working and red attention signals; original lighting restored |
| WI-012 | Implement native official-feature parity | lead | local application and SayoDevice O2L V2 | protocol and macOS | completed | E-011 | Key modes, effects, palettes, text/passwords, scripts, identity, backup/restore; destructive maintenance gated |

## Coverage
- [x] Recon/analysis complete for in_scope assets
- [x] Critical/High candidates triaged (N/A for pure RE)
- [x] Validated findings have Evidence (E-*)
- [x] Path documented (callflow)
- [x] Timeline continuous across major phases
- [x] Report generated
- [x] field-journal anonymized

## Refs
- skills/ops/timeline-workitem.md
- skills/ops/evidence-finding-path.md
