# Task: Mayor System

## Goal
Implement the Mayor lifecycle, queue handling integration, skills scaffolding, and memory structure so automation can invoke Mayor actions end-to-end.

## Scope
- Mayor session management commands.
- Stop hook installation path and state path detection.
- Mayor skills files in `skills/` directory.
- Mayor memory templates under `templates/mayor/`.
- Briefing/status integration in CLI.

## Deliverables
- `pai-lite mayor start|stop|status|attach|logs` commands.
- `pai-lite init` optionally installs stop hook to a pai-lite-specific path (e.g., `~/.claude/hooks/pai-lite-on-stop.sh`) — don't overwrite existing hooks.
- Stop hook uses `PAI_LITE_STATE_PATH` or derives state path safely.
- Skills: `/briefing`, `/suggest`, `/analyze-issue`, `/elaborate`, `/health-check`, `/learn`, `/sync-learnings`, `/techdebt`, `/context-sync`.
- Mayor memory templates — see ARCHITECTURE.md "Mayor memory" section for structure (`mayor/context.md`, `mayor/memory/` subfiles).
- `pai-lite briefing` queues Mayor, waits for result, renders `briefing.md`, notifies.
- `pai-lite status` includes Mayor status (if available).

## Files to Touch
- `bin/pai-lite` (mayor + briefing/status integration)
- `lib/common.sh` (mayor wait helper, if needed)
- `templates/hooks/pai-lite-on-stop.sh`
- `templates/mayor/` (new)
- `skills/` (new)
- `templates/config.example.yaml` + `templates/harness/config.yaml` (mayor config sections)

## Suggested Approach
1) Add Mayor session commands first (tmux-based like claude-code).
2) Update stop hook to discover state path (prefer `PAI_LITE_STATE_PATH`, fallback to pointer config).
3) Add skills scaffolding with clear I/O expectations and file outputs.
4) Add memory templates under `templates/mayor/`.
5) Wire `pai-lite briefing` to queue + wait + notify.

## Dependencies
- Queue implementation already exists in `lib/common.sh`.
- Notifications are already in `lib/notify.sh`.

## Validation
- Run shellcheck on changed scripts.
- Manual sanity check:
  - `pai-lite mayor start`
  - `pai-lite mayor briefing` queues and stop hook emits `/briefing`.
  - Results written to `tasks/results/<id>.json`.

## Out of Scope
- Dashboard generation.
- Trigger expansion.
- CI integration.

## Risks
- `bin/pai-lite` and config templates overlap with other tracks.
- Skills content needs to be consistent with actual file paths and data formats.
