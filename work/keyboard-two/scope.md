# Case Scope

## meta
- case_id: keyboard-two
- created: 2026-08-29T15:58:38-07:00
- operator: local
- project_root: local checkout (redacted for publication)
- primary_skill: protocol-reverse/SKILL.md
- primary_id: R21
- lead_role: lead
- specialist_roles: []
- hint: locally owned USB HID keyboard hardware inspection and report protocol reverse engineering
- preset: own-system

## auth
- status: granted
- basis: own_system
- evidence_of_auth: preset:own-system/lab
- MUST NOT proceed if status != granted

## in_scope
- assets:
  - local-connected-keyboard-2
- surfaces: []
- activities: []

## out_of_scope
- assets: []
- activities: [dos, phishing_real_users, unrestricted_exfil]

## network_profile
- mode: lab_only
- notes: |
    offline | lab_only | authorized_target_only | unrestricted_lab
    Change mode only after auth.status = granted.
    Presets: offline-sample | ctf-public | own-system

## deliverables
- report: true
- field_journal: true
- diagrams: true
- timeline: true

## constraints
- timebox: {}
- stealth: low
- data_handling: anonymize

## signoff
- ready_for_act: true
- checklist:
  - [x] auth.status = granted
  - [x] in_scope.assets non-empty OR offline sample path set
  - [x] network_profile.mode chosen
  - [x] out_of_scope reviewed
  - [x] roles assigned (lead; no specialists required)

## ops_refs
- skills/ops/scope-contract.md
- skills/ops/evidence-finding-path.md
- skills/ops/role-map.md
- skills/ops/timeline-workitem.md
- skills/ops/IDENTITY.md
