# Codex App: Integration Ideas for ludics & agent-duo

*Research notes from 2026-02-09. Based on https://developers.openai.com/codex/app/ and related docs.*

## What the Codex App Is

The Codex App is a **native macOS desktop application** (Windows/Linux planned) serving as a
command center for running multiple Codex coding agent threads in parallel. Included with
ChatGPT Plus/Pro/Business/Edu/Enterprise plans. Key differentiator from the CLI: full GUI with
built-in git tooling, worktree isolation, visual diff review, and automations.

## Core Features

| Feature | Details |
|---|---|
| **Parallel Threads** | Multiple concurrent agent conversations, each isolated |
| **Git Worktrees** | Auto-creates worktrees per thread so changes don't conflict |
| **Visual Diff Review** | Inline commenting, chunk staging/reverting, commit — all in-app |
| **Automations** | Background recurring tasks; findings go to an inbox or auto-archive |
| **Skills** | Reusable across App, CLI, and IDE Extension |
| **MCP Integration** | Connect to third-party tools via `~/.codex/config.toml` |
| **Setup Scripts** | Per-project worktree init scripts and action shortcuts |

## The App Server Protocol (key discovery)

`codex app-server` — a JSON-RPC 2.0 over JSONL bidirectional protocol on stdio.
Same backend that powers the VS Code extension, fully documented for third-party integration.

```bash
codex app-server
```

### Key Primitives

| Primitive | Methods |
|---|---|
| **Thread** | `thread/start`, `thread/resume`, `thread/fork`, `thread/read`, `thread/list`, `thread/archive` |
| **Turn** | `turn/start` (send user message), `turn/interrupt` |
| **Review** | `review/start` (inline or detached code review) |
| **Command** | `command/exec` (run shell command without a thread) |
| **Model** | `model/list` |
| **Skills** | `skills/list` |

### Event Streaming

After starting a turn, the server emits notifications:
- `turn/started`, `turn/completed`, `turn/diff/updated`, `turn/plan/updated`
- `item/started`, `item/completed`, `item/agentMessage/delta`
- `item/commandExecution/requestApproval` (approval workflows)
- `thread/tokenUsage/updated`

### Turn Configuration Overrides

Per-turn settings: `model`, `effort`, `personality`, `cwd`, `sandboxPolicy`,
`approvalPolicy`, `summary`, `outputSchema`.

### Sandbox Policies

- `workspaceWrite` — write access to specified roots
- `readOnly` — read-only execution
- `dangerFullAccess` — unrestricted (development only)
- `externalSandbox` — host app handles sandboxing

### Authentication Modes

- **API Key** — caller supplies OpenAI key
- **ChatGPT Managed** — Codex owns OAuth flow with auto-refresh
- **External Tokens** — host app supplies `idToken` and `accessToken`

### Schema Generation

```bash
codex app-server generate-ts --out ./schemas
codex app-server generate-json-schema --out ./schemas
```

## Unified Thread Store (critical finding)

**All Codex clients share a single thread store** on the local filesystem (JSONL log files).

The `thread/list` method has a `sourceKinds` filter accepting: `cli`, `vscode`, `exec`,
`appServer`, and others. This means:

- A thread started via `codex` CLI shows up in the Codex App GUI
- A thread started via app-server shows up in the Codex App GUI
- Any client can `thread/resume` any thread regardless of origin
- Threads organized into "active sessions" and "archived sessions" directories

### Architecture

```
                    ┌──────────────────────┐
                    │  Codex Thread Store   │
                    │  (local JSONL files)  │
                    └──────┬───────────────┘
                           │ shared
          ┌────────────────┼────────────────┐
          │                │                │
   ┌──────┴──────┐  ┌─────┴──────┐  ┌──────┴───────┐
   │ Codex App   │  │ codex CLI  │  │ app-server   │
   │ (GUI)       │  │ (tmux/tty) │  │ (JSON-RPC)   │
   │             │  │            │  │              │
   │ human views │  │ ttyd →     │  │ ludics →   │
   │ & interacts │  │ tailscale  │  │ codex-app.sh │
   └─────────────┘  └────────────┘  └──────────────┘
```

## Codex SDK (TypeScript)

```bash
npm install @openai/codex-sdk
```

```typescript
const codex = new Codex();
const thread = codex.startThread();
const result = await thread.run("Fix the login bug");
// Resume later:
const resumed = codex.resumeThread(threadId);
```

For CI/CD and programmatic control. Server-side Node.js 18+.

## MCP Configuration

Settings in `~/.codex/config.toml` (or project-scoped `.codex/config.toml`).

**STDIO servers**: `command`, `args`, `env`, `cwd`
**HTTP servers**: `url`, `bearer_token_env_var`, `http_headers`
**Universal options**: `startup_timeout_sec`, `tool_timeout_sec`, `enabled`, `enabled_tools`, `disabled_tools`

CLI and IDE extension share configuration — skills and MCP are portable across all clients.

## No Remote Access

The Codex App has **no remote/server-client architecture**. It is purely a local macOS desktop
app. The app-server is stdio-only — no TCP, no WebSocket, no daemon mode.

The tmux + ttyd + tailscale stack remains unmatched for remote access:

```
codex-cli path:  Phone → Tailscale → ttyd → tmux → codex CLI  ✅
codex-app path:  Phone → ??? → Codex App (macOS-only)          ❌
```

However, since all clients share the thread store, a thread started remotely via CLI is
visible in the App GUI when you return to your Mac.

---

## Adapter Evolution: Observer, Not Launcher

### Current `codex.sh` approach

The existing adapter manages tmux sessions, state files, PIDs — it's a **launcher**.
This is fine for agent-duo dispatched sessions but doesn't see sessions started via
VS Code extension, the Codex App GUI, or bare CLI invocations.

### Target: pervasive session discovery

The adapter should **discover all Codex sessions** regardless of how they were started,
by reading the shared thread store. The same principle applies to Claude Code sessions.

```
codex.sh read_state:
  1. Check tmux for codex-related sessions (existing behavior)
  2. NEW: Scan ~/.codex/sessions/*.jsonl for active threads
     - Filter by cwd matching known project directories
     - Extract: thread ID, model, last activity, source (cli/app/vscode)
  3. Correlate: tmux session ↔ thread ID (same cwd = same session)
  4. Report unified view regardless of entry point
```

### CLI-first workflow (recommended)

Start Codex sessions via CLI (tmux/ttyd/tailscale for remote access). The Codex App
becomes a **free read/review layer** — CLI-started threads are visible in the App GUI
automatically since all clients share the thread store.

What you keep: full remote access, agent-duo worktree management, no cleanup risk.
What you get for free: App's visual diff review, inline comments, thread browsing.

### Task dispatch stays simple

ludics Mag dispatches tasks via shell commands — `agent-duo start`, `agent-solo start`,
etc. No app-server protocol needed in ludics. If Codex App dispatch integration is
desired (e.g., app-server for more reliable Codex management), that responsibility
belongs in the **agent-duo project**.

---

## Implications for agent-duo

agent-duo currently launches `codex --yolo` via `tmux send-keys` and uses fragile buffer
scraping (`get_codex_resume_key()`) for crash recovery.

### Potential app-server integration (agent-duo's concern, not ludics's)

| Responsibility | agent-duo today | With app-server |
|---|---|---|
| Agent dispatch | `tmux send-keys "codex --yolo"` | `turn/start` with input |
| Status detection | Completion hooks (`agent-duo-notify`) | `turn/completed` events |
| Resume after crash | Buffer scraping for resume key | `thread/resume(threadId)` |
| Diff review | `git diff` in peer worktree | `turn/diff/updated` event stream |
| Approval policy | `--yolo` | `sandboxPolicy` per turn |

Note: agent-duo would keep managing its own worktrees (`git worktree add` with named
branches). The `cwd` turn override tells app-server where to work.

---

## Cross-System Integration Ideas

### 1. ludics MCP Server (optional, lower priority)

Expose ludics as an MCP server so any Codex/Claude thread can self-serve:

```toml
# ~/.codex/config.toml
[mcp_servers.ludics]
command = "ludics"
args = ["mcp-server"]
```

Tools: `task_list`, `task_claim`, `task_complete`, `slot_status`, `escalate`

### 2. Skills Portability

agent-duo already installs skills to `~/.codex/skills/`. The Codex App shares this
directory. A human using the App GUI can invoke `/duo-work` in a thread. The app-server's
`skills/list` method enumerates them.

### 3. Thread ID as Universal Handle

If ludics adapters learn to read `~/.codex/sessions/`, the thread ID becomes a
universal handle. Any client (App, CLI, SDK) can resume or inspect a thread that
ludics is tracking in its slot view.

---

## Revised Design Philosophy

### ludics's two roles: monitor everything, dispatch simply

**Monitoring** should be pervasive and automatic — ludics discovers and tracks all
agentic sessions running on the system (or across Tailscale machines), regardless of
how they were started. The adapter is an **observer**, not a launcher.

**Dispatch** should not require much ludics infra. Mag already executes shell
commands — it can run `agent-duo start`, `agent-solo start`, etc. If Codex App
dispatch integration is desired (e.g., via app-server), that belongs in the
**agent-duo project**, not in ludics.

### Implications

1. **No `codex-app.sh` adapter needed for dispatch** — Mag dispatches via
   `agent-duo` / `agent-solo` CLI commands, which handle all session setup
2. **The adapter becomes a session discoverer** — reads `~/.codex/sessions/`,
   `~/.claude/projects/`, `.peer-sync/`, tmux sessions, etc.
3. **Agent-duo owns Codex App integration** — if agent-duo wants to use app-server
   for more reliable Codex management, that's agent-duo's concern
4. **ludics stays thin** — its value is the unified view across all agents,
   not reimplementing each agent's session management

### CLI-first, App as read/review layer

The pragmatic approach: start all Codex sessions via CLI (tmux/ttyd/tailscale for
remote access), and use the Codex App as a bonus read/review layer when at the Mac.
Since all Codex clients share the thread store (`~/.codex/sessions/`), CLI-started
threads are visible in the App GUI automatically. You lose nothing — no worktree
management conflict, no cleanup risk, full remote access retained.

### Priority Roadmap

| Priority | What | Owner | Why |
|---|---|---|---|
| **1** | Pervasive session discovery in adapters | ludics | Track all sessions automatically |
| **2** | Read `~/.codex/sessions/` for Codex thread state | ludics | Observe CLI/App/Extension sessions |
| **3** | Read `~/.claude/projects/` for Claude Code state | ludics | Observe all Claude sessions |
| **4** | Cross-machine session discovery via Tailscale | ludics | Federation-aware monitoring |
| **5** | App-server integration for Codex dispatch | agent-duo | Eliminate fragile TUI mgmt |
| **6** | ludics MCP server | ludics | Self-aware agents (optional) |

---

## Detailed Documentation Pages

### Features (from /codex/app/features)

**Execution Modes** — three modes when creating threads:
- **Local**: work directly in project directory
- **Worktree**: isolated changes using git worktrees (parallel tasks)
- **Cloud**: remote execution in configured cloud environments

**Skills & Automations**: agent skills consistent across CLI/IDE Extension/App. Automations
combine skills for routine tasks, run in dedicated background worktrees.

**Git Integration**: diff pane with inline commenting, stage/revert chunks or files, commit,
push, create PRs — all in-app. Advanced ops via integrated terminal.

**Terminal**: scoped to each project/worktree, toggle with Cmd+J. Cmd+K = command palette,
Ctrl+L = clear terminal.

**Input**: voice dictation (hold Ctrl+M), image drag-and-drop (Shift+drop), IDE extension
auto-context sync.

**Other**: web search (first-party, enabled by default), notifications for task
completion/approvals, sleep prevention toggle.

### Settings (from /codex/app/settings)

**General**: file opening behavior, command output display, multiline prompt (Cmd+Enter),
sleep prevention.

**Appearance**: theme, window style (solid/transparent), UI font, code font.

**Notifications**: completion alerts, permission prompts.

**Agent Config**: inherited from IDE/CLI; common settings in-app, advanced in `config.toml`.

**Git Settings**:
- Branch naming standardization (enforce conventions)
- Force push usage (allow/disallow)
- Commit message prompts (custom prompts for generation)
- PR description prompts (custom prompts)

**Integrations & MCP**: enable recommended servers, add custom, OAuth config. Shared
across CLI/IDE/App via `config.toml`.

**Personalization**: personality modes ("Friendly", "Pragmatic", "None"), custom
instructions (updates `AGENTS.md`).

**Archived Threads**: view/unarchive archived chats with dates and project context.

**Access**: Cmd+, keyboard shortcut.

### Review (from /codex/app/review)

The review pane displays **actual Git repository state** — Codex changes, manual edits,
and any uncommitted modifications.

**Scope options**:
- **Uncommitted changes** (default)
- **All branch changes** (compared against base branch)
- **Last turn changes** (most recent assistant response only)
- Toggle between **Unstaged** and **Staged** for local work

**Inline Comments**:
1. Hover over diff line → click **+** button
2. Submit feedback
3. Send follow-up message: "Address the inline comments"
4. Comments from `/review` operations also shown inline

**Staging/Reverting granularity**: entire diff, individual files, or single hunks.
Mixed staged/unstaged in same file is supported.

**Requirement**: project must be a Git repo.

**Implications for ludics/agent-duo**:
- The review pane shows all uncommitted changes, not just Codex's — this means
  agent-duo's peer-review workflow (where one agent reviews the other's worktree)
  could be visualized in the Codex App if the agent's worktree is added as a project.
- Inline comments feature parallels agent-duo's review phase — agents write review
  files, but the Codex App offers a richer visual experience for the same function.

### Automations (from /codex/app/automations)

**Setup**: creation form with **schedule** and **prompt** fields. Recurring background tasks.

**Requirements**: app must be running and project available on disk.

**Execution environment**:
- Git repos: run in **dedicated background worktrees** (no interference with main checkout)
- Non-git projects: run directly in project directory
- Uses default sandbox settings

**Results**: populate a "Triage" section (inbox). Auto-archives runs with nothing to report.
Filter: all runs or unread only.

**Skills integration**: trigger skills via `$skill-name` syntax in automation prompt.

**Management**: automations pane in sidebar. Archive runs to clean up accumulated worktrees.
Don't pin runs unless you want to preserve worktrees permanently.

**No programmatic API** for creating automations — UI only.

**Implications for ludics**:
- Automations overlap with ludics's trigger system (periodic health checks, syncs)
- The "Triage" inbox is analogous to Mag's inbox/queue
- A ludics trigger could prompt a Codex automation result check, pulling findings
  into the briefing system
- Limitation: no API means automations can't be created programmatically by ludics —
  they're a human-configured feature

### Worktrees (from /codex/app/worktrees)

**Creation**: via thread composer — select "Worktree" and choose starting branch.
Optionally specify local environment for setup scripts.

**Location**: stored under `$CODEX_HOME/worktrees` (not customizable).
Default `$CODEX_HOME` is `~/.codex`.

**State**: created in **detached HEAD** — avoids polluting branch namespace.
Multiple parallel worktrees allowed.

**Thread-Worktree relationship**: each worktree tied to a thread. Threads persist in
history even after worktree cleanup. Snapshots auto-saved before deletion for restoration.

**Cleanup policy**:
- Auto-deleted when: older than 4 days AND archived, or more than 10 worktrees exist
- **Protected**: pinned conversations or sidebar-added worktrees never deleted

**Limitation**: can't customize worktree location or move sessions between worktrees.
Git prevents simultaneous branch checkout across worktrees.

**Implications for agent-duo**:
- **Conflict with agent-duo's worktree scheme**: agent-duo creates worktrees at
  `~/project-feature-agent/` with named branches (`feature-claude`, `feature-codex`).
  The Codex App creates worktrees at `~/.codex/worktrees/` in detached HEAD.
  These are incompatible naming/location conventions.
- **For hybrid integration**: agent-duo should keep managing its own worktrees and
  point Codex (via app-server) at those worktrees using the `cwd` turn override,
  rather than letting the App create its own worktrees.
- **Cleanup risk**: the App's auto-cleanup (4 days + archived) could delete worktrees
  agent-duo is still using. If using App-managed worktrees, they'd need to be pinned.

### Local Environments (from /codex/app/local-environments)

**Setup scripts**: execute automatically when Codex initializes a new worktree.
Example: `npm install && npm run build` for TypeScript projects.

**Platform-specific**: separate setup commands for macOS/Windows/Linux.

**Actions**: frequently-used tasks accessible from top bar (dev servers, test suites,
builds). Custom icons supported. OS-specific variants available.

**Configuration**: stored in `.codex` folder at project root. Version-controllable.

**Implications for ludics**:
- The `.codex/` project config folder is analogous to `.claude/` — both are
  project-level agent configuration.
- ludics could generate `.codex/` setup scripts as part of task elaboration,
  ensuring Codex threads have the right environment.
- Action shortcuts could be defined to run ludics commands
  (e.g., "Claim next task", "Report status").

### Troubleshooting (from /codex/app/troubleshooting)

**Key filesystem paths**:

| Path | Contents |
|---|---|
| `~/Library/Logs/com.openai.codex/YYYY/MM/DD` | App logs (macOS) |
| `$CODEX_HOME/sessions` (`~/.codex/sessions`) | Session transcripts (JSONL) |
| `$CODEX_HOME/archived_sessions` (`~/.codex/archived_sessions`) | Archived sessions |
| `$CODEX_HOME/worktrees` (`~/.codex/worktrees`) | App-managed worktrees |
| `.codex/` (project root) | Local environment config |

**Common issues**:
- Review panel shows all Git changes, not just Codex — switch to "Last turn changes"
- Worktrees inherit only Git-tracked files — need setup scripts for deps
- Terminal stuck: close (Cmd+J), run basic commands, restart app if needed

**Implications for ludics**:
- `~/.codex/sessions/*.jsonl` is the thread store — `codex-app.sh` adapter could
  read these directly for status without needing app-server, as a fallback
- Log location useful for `adapter_codex_app_doctor()` health checks
- The `$CODEX_HOME` env var can override all paths — useful for isolation in
  multi-user or testing scenarios

---

## Revised Integration Analysis (post-detailed-review)

### Adapter as Universal Observer

The key architectural shift: ludics adapters should **discover sessions** rather than
**create them**. Data sources for pervasive monitoring:

| Source | What it reveals | Agent |
|---|---|---|
| `~/.codex/sessions/*.jsonl` | All Codex threads (CLI, App, VS Code) | Codex |
| `~/.claude/projects/` | All Claude Code sessions | Claude Code |
| `.agent-sessions/*.session` symlinks | agent-duo/solo orchestrated sessions | Multi-agent |
| `.peer-sync/` state files | Phase, round, agent status, worktrees | Multi-agent |
| `tmux ls` | Active terminal sessions | Any CLI agent |
| ttyd PIDs / ports | Web-accessible terminals | Any CLI agent |

For cross-machine monitoring via Tailscale, the state repo (already synced via git)
carries slot assignments and task status. The federation system could additionally
poll remote machines for their `~/.codex/sessions/` and tmux state.

### Worktree Conflict: Non-Issue

Since ludics doesn't create Codex sessions and agent-duo manages its own worktrees,
the Codex App's worktree scheme (`~/.codex/worktrees/`, detached HEAD, auto-cleanup)
is irrelevant. CLI-started sessions use whatever `cwd` they were launched in.
The App sees those threads read-only without creating conflicting worktrees.

### Automations as Complement to Triggers

Codex App automations are human-configured, scheduled, GUI-only. ludics triggers are
programmatic, event-driven, scriptable. They complement rather than compete:
- ludics triggers for: task sync, health checks, Mag keepalive, file watching
- Codex automations for: "scan telemetry for errors daily", "generate weekly report"
- Bridge: ludics briefing could ingest Codex automation triage results

### Review Pane as agent-duo Visualization

The App's review pane (showing uncommitted changes with inline comments) could serve as
a richer UI for agent-duo's review phase — add agent worktrees as App projects, and
the human gets visual diff review instead of reading markdown review files.

### `.codex/` Project Config

Teams could version-control `.codex/` alongside `.claude/` for consistent agent setup.
ludics's task elaboration could generate setup scripts and actions in `.codex/`.

### Responsibility Split

| Concern | Owner | Mechanism |
|---|---|---|
| Session monitoring | ludics adapters | Read session stores, tmux, .peer-sync |
| Task dispatch | ludics Mag | Shell commands: `agent-duo start`, etc. |
| Codex App integration | agent-duo | app-server protocol (if/when needed) |
| Worktree management | agent-duo | `git worktree add` (own scheme) |
| Skills & MCP config | Shared | `~/.codex/config.toml`, `~/.codex/skills/` |
| Remote access | ludics + agent-duo | tmux/ttyd/tailscale |
