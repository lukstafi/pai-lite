# Changelog

## v0.2.0 — 2026-02-11

Second release. Focus on robustness, better Mayor workflows, and task management improvements.

### New features

- **Task merging and duplicate detection** — `flow duplicates` finds near-duplicate tasks; `tasks merge` combines them with dependency rewiring.
- **Content-fingerprint task IDs** — Watch-path tasks now use 8-char md5 of normalized text (`watch-<path>-<fingerprint>`) instead of line numbers, so IDs survive file edits. Old IDs are migrated automatically.
- **Cross-reference migration** — `tasks migrate-refs` updates `blocks`/`blocked_by` references after ID changes.
- **Pervasive session discovery** — `sessions list` scans tmux, screen, VS Code, and `.peer-sync/` directories to find all active agent sessions, enriching slot data.
- **Mayor inbox** — Async message channel (`mayor inbox send/read`) for non-blocking communication with the Mayor session. Briefing and health-check skills read the inbox automatically.
- **Briefing context pre-computation** — Bash pre-computes slot state, ready queue, and critical items before invoking the briefing skill, reducing token usage.
- **Proactive slot management** — Mayor briefing now includes slot occupancy analysis and reassignment suggestions.
- **Dashboard briefing tab** — New tab renders the latest briefing as formatted Markdown alongside terminals and task views.
- **Lazy dashboard server** — Dashboard HTTP server auto-starts via launchd/systemd on first `dashboard open` and stops when idle.
- **Mayor keepalive nudge** — When the keepalive trigger fires, if the Mayor queue is non-empty the nudge includes a timestamp and pending item count.
- **CLAUDE.md template for harness directories** — `pai-lite init` deploys a CLAUDE.md with project conventions and upstream-PR workflow into each harness directory.

### Fixes

- **Flow engine glob** — Fixed task file matching to include all `*.md` files with YAML frontmatter, not just `task-*.md`.
- **`printf` with dash-prefixed strings** — `log_info`/`log_error` no longer fail when the message starts with a dash.
- **Mayor keepalive timestamp** — Nudge messages now include the current time for log traceability.

### Other changes

- **Mayor queue path** — `queue.jsonl` and `results/` moved from `harness/tasks/` to `harness/mayor/` for clearer separation.
- **Removed `/pai-context-sync` skill** — Redundant with existing automation; removed to reduce surface area.
- **Test script** — Added `tests/test.sh` with shellcheck linting and smoke tests for core commands.
- **Archived PLAN.md** — Original v0.1 plan moved to `docs/PLAN-v0.1-archive.md`.

---

## v0.1.0 — 2026-02-08

First release of pai-lite: a lightweight personal AI infrastructure for humans working with AI agents.

### What works well (tested in daily use)

- **macOS launchd integration** — Startup, periodic sync, and Mayor keepalive triggers install and fire reliably. Templates include proper PATH for Homebrew Bash 4+.
- **Task generation from sources** — GitHub issues (via `gh`), Markdown checkboxes, and watch rules on file changes all aggregate into `tasks.yaml` and convert to individual `task-*.md` files with YAML frontmatter.
- **Briefings** — Morning briefing generation gathers slot state, ready queue, critical items, stalled work, and approaching deadlines into a Markdown report. Same-day briefings are amended rather than regenerated. Auto-committed to the state repo.
- **Elaboration** — High-level tasks are expanded into detailed specs with subtasks, file references, edge cases, and test suggestions. Proactive elaboration queues unprocessed ready tasks automatically.
- **Autonomous Mayor operation** — A persistent Claude Code session in tmux with queue-based communication. Automation writes requests to `mayor/queue.jsonl`; the stop hook drains the queue when Claude goes idle. Skills are invoked via tmux send-keys. ttyd provides web access.

### What's included but not yet battle-tested

These components are implemented and may work, but have seen little to no real-world use. Expect rough edges.

- **Slot system** — The 6-slot model for tracking parallel work: assign, clear, start, stop, notes. Adapter state refresh. The data model is there; the workflow around it hasn't been exercised.
- **Dashboard** — HTML5 + JS web UI with slot grid, task views, flow visualization, and terminal iframes. JSON generation from Markdown state works. The frontend renders but hasn't been polished.
- **Adapters** — Seven adapters (agent-duo, agent-solo, claude-code, claude-ai, chatgpt-com, codex, manual) following a consistent `read_state/start/stop` interface. Only claude-code has been used meaningfully.
- **Linux systemd support** — Service and timer unit templates mirror the launchd functionality. Untested on actual Linux systems.
- **Federation** — Multi-machine coordination with seniority-based leader election, heartbeats, and Tailscale networking. Implemented but not deployed.
- **Notification system** — 3-tier ntfy.sh integration (pai/agents/public) with local journal logging. Wiring is in place; delivery hasn't been verified end-to-end.

### Full feature list

#### Core CLI (`bin/pai-lite`)
- 35+ commands across slots, tasks, flow, mayor, notify, dashboard, state, journal, network, federation, and setup
- Self-installing (`pai-lite init`) with hooks, triggers, and skills auto-deployment
- `pai-lite doctor` for environment validation

#### Task management
- Multi-source aggregation: GitHub issues, README checkboxes, file watch rules
- YAML frontmatter format: id, title, project, status, priority (A/B/C), deadline, dependencies, effort, context, adapter
- Dependency tracking with `blocks`/`blocked_by` and cycle detection via `tsort`
- Deterministic IDs: `gh-<repo>-<number>` for issues, `watch-<path>-<fingerprint>` for file sources (8-char md5 of normalized text; migrates old line-number-based IDs automatically)

#### Flow engine
- `flow ready` — priority-sorted, dependency-filtered, deadline-aware queue
- `flow blocked` — dependency graph of blocked tasks
- `flow critical` — approaching deadlines + stalled work (>7 days in-progress)
- `flow impact` — what completing a task unblocks
- `flow context` — active slots per context tag
- `flow check-cycle` — topological validation of dependency graph

#### Mayor system
- Persistent Claude Code session in tmux with ttyd web access
- Queue-based communication (`queue.jsonl` + `results/<id>.json`)
- Stop hook fires on Claude idle to drain the queue
- Keepalive trigger (every 15 min) restarts Mayor if needed
- Institutional memory: corrections, tools, workflows, project-specific knowledge

#### Skills (9 total)
- `pai-briefing` — morning briefing with same-day amending
- `pai-elaborate` — task-to-spec expansion
- `pai-suggest` — next-task recommendations
- `pai-analyze-issue` — GitHub issue to actionable task
- `pai-health-check` — stalled work detection
- `pai-learn` — record corrections to institutional memory
- `pai-sync-learnings` — consolidate corrections into knowledge files
- `pai-techdebt` — technical debt tracking

#### Triggers
- macOS launchd: startup, periodic sync, morning briefing, Mayor keepalive
- Linux systemd: equivalent service + timer units
- Watch rules: file change triggers for task sync
- `pai-lite triggers install/status/uninstall`

#### Implementation
- Pure Bash 4+ with CLI tools: `yq`, `jq`, `tsort`, `gh`, `tmux`, `ttyd`
- Git-backed state in a separate private repo
- Config via YAML (`yq eval`), no awk parsing
- POSIX-compatible where possible

### Known issues

- `declare -gA` in `slots.sh` requires Bash 4+; macOS ships Bash 3. Launchd plists include `/opt/homebrew/bin` in PATH to find Homebrew's Bash.
- The installed copy at `~/.local/pai-lite/` is a file copy, not a symlink. Changes to the working copy must be manually re-installed.
- `[[ condition ]] && echo` at end of functions is unsafe under `set -e`; mitigated throughout but worth noting for contributors.
