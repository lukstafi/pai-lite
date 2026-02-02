# Task: Ops + Config

## Goal
Harden operational tooling: config parsing/templates, triggers, and doctor checks.

## Scope
- Config parsing helpers for `mayor.*` and `notifications.*`.
- Update config templates with mayor/notifications sections.
- Trigger expansion (morning/health/watchpaths) + status/uninstall.
- `pai-lite doctor` comprehensive checks.

## Deliverables
- Config helpers in `lib/common.sh` (or new lib) for mayor/notifications.
- Updated templates:
  - `templates/config.example.yaml`
  - `templates/harness/config.yaml`
- Trigger updates in `lib/triggers.sh`:
  - StartCalendarInterval (morning briefing)
  - StartInterval (health check)
  - WatchPaths (repo change)
  - Startup trigger (on login)
  - `triggers status` + `triggers uninstall`
- `pai-lite doctor` command with required/optional tool checks.

## Files to Touch
- `lib/common.sh` (config helpers)
- `lib/triggers.sh`
- `bin/pai-lite` (doctor + trigger subcommands)
- `templates/config.example.yaml`
- `templates/harness/config.yaml`

## Suggested Approach
1) Add config helpers using `yq` (already a dependency per ARCHITECTURE.md).
2) Expand templates with mayor/notifications sections.
3) Extend triggers install with additional trigger types + status/uninstall.
4) Implement `pai-lite doctor` command, reuse adapter doctor functions where available.

## Dependencies
- Mayor track for precise mayor config fields.
- Slot/task track for state sync expectations.

## Validation
- Run shellcheck on changed scripts.
- Manual sanity check:
  - `pai-lite triggers install`
  - `pai-lite triggers status`
  - `pai-lite doctor`

## Out of Scope
- Dashboard generation.
- Mayor skills content.

## Risks
- `bin/pai-lite` merge conflicts with other tracks.
