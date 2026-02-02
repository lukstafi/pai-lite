# Task: Dashboard

## Goal
Complete the read-only dashboard pipeline: generate JSON data, serve/install the dashboard, and add the terminal grid view.

## Scope
- Dashboard data generation from slots/tasks/journal/mayor status.
- Serve/install commands in CLI.
- Terminal grid view HTML/JS.

## Deliverables
- `pai-lite dashboard generate` produces:
  - `dashboard/data/slots.json`
  - `dashboard/data/ready.json`
  - `dashboard/data/notifications.json`
  - `dashboard/data/mayor.json`
- `pai-lite dashboard serve` starts a local HTTP server.
- `pai-lite dashboard install` copies templates to state repo.
- `templates/dashboard/terminals.html` with 3x2 ttyd grid and tab support.
- Shared schema documented (slots.json, mayor.json).

## Files to Touch
- `bin/pai-lite` (dashboard subcommands)
- `lib/flow.sh` (ready output helper, if needed)
- `lib/slots.sh` (slots -> JSON helper, if needed)
- `templates/dashboard/*`
- `docs/ARCHITECTURE.md` (only if schema clarifications needed)

## Suggested Approach
1) Define JSON schemas for slots/mayor/ready/notifications.
2) Build `dashboard generate` using existing slot/task/journal sources.
3) Add serve/install commands.
4) Implement `terminals.html` + JS (tabs per slot).

## Dependencies
- Requires stable `slots.md` schema and task format.
- Mayor status schema should match mayor session mgmt output.

## Validation
- Run `pai-lite dashboard generate` and open `templates/dashboard/index.html` via `serve`.
- Confirm dashboard renders with placeholder or real data.

## Out of Scope
- Mayor session management.
- Trigger expansion.
- CI integration.

## Risks
- JSON schema coupling to slot/Mayor formats. Coordinate before finalizing.
