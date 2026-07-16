---
id: NIXGC-1
title: Add nix mock test harness
status: To Do
assignee: []
created_date: '2026-07-16 11:41'
labels:
  - testing
  - ci
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
gc-plan.sh shells out to `nix`, `nix-store`, and `nix path-info`. To test its logic (dead-path enumeration, registrationTime/atime ordering, greedy selection, pinned-path skipping, and portable mount/atime detection) without a real Nix store, add mock CLIs whose output is byte-compatible with the real tools for the commands and flags the script uses. Tests activate the mocks by PATH-prefixing tests/mocks/ so they shadow the real binaries — the script under test is not modified. Each test script drives a distinct scenario. The suite is wired into the justfile and run by GitHub CI inside the nix dev shell.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 New tests/ folder with tests/mocks/ containing mock scripts (at least `nix` and `nix-store`) that reproduce the exact output gc-plan.sh parses: `nix-store --gc --print-dead` (newline path list) and `nix path-info --json --stdin` (object keyed by path with registrationTime + narSize).
- [ ] #2 Mock output shape matches the real nix CLI for the used subcommands/flags; scenarios are data-driven (a fixture selects which dead set / times / sizes the mocks emit).
- [ ] #3 Mocks are activated purely by prefixing tests/mocks/ onto PATH; gc-plan.sh itself is unchanged.
- [ ] #4 Each test script covers a distinct scenario: target met, target not met (dead set too small), empty dead set, null registrationTime path, atime frozen (ro/noatime) vs rw-with-post-birth-reads, and pinned-path skip on --delete.
- [ ] #5 A justfile recipe (e.g. `just test`) runs the whole suite and exits non-zero on any failure.
- [ ] #6 A GitHub Actions workflow runs `just test` on push and PR, using the flake dev shell so shellcheck and deps are available.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 All test scenarios pass locally via `just test`.
- [ ] #2 CI workflow is green on a pushed branch.
<!-- DOD:END -->
