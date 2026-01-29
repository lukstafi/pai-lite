# pai-lite Architecture

## Overview

pai-lite is a lightweight personal AI infrastructure — a harness for humans working with AI agents. It manages concurrent agent sessions (slots), aggregates tasks from multiple sources, and triggers actions on events.

## Core Concepts

### The Slot Model

Inspired by human working memory (~4 pointer slots with chunking), pai-lite manages **6 slots** by default. Each slot is like a CPU:

```
┌─────────────────────────────────────────────────────────────┐
│                        SLOT                                 │
├─────────────────────────────────────────────────────────────┤
│  Process:     What's currently running (task/project)       │
│  Mode:        How it's running (agent-duo, claude-code...)  │
│  Runtime:     State held while active (context, questions)  │
│  Terminals:   Links to TUIs, orchestrators                  │
│  Git:         Worktrees, branches                           │
└─────────────────────────────────────────────────────────────┘
```

**Key properties:**
- Slots have no persistent identity — slot 3 isn't "the OCANNL slot"
- Context switching has a cost (like real CPUs)
- Runtime state is lost when the slot is cleared
- The work itself persists (commits, issues, notes) — only the "registers" are ephemeral

### Task Aggregation

Tasks come from multiple sources:

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   GitHub Issues  │     │   README TODOs   │     │  Private Chores  │
│   (per project)  │     │   (parsed)       │     │  (self-improve)  │
└────────┬─────────┘     └────────┬─────────┘     └────────┬─────────┘
         │                        │                        │
         └────────────────────────┼────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │   Unified Task Index    │
                    │   (tasks.yaml)          │
                    └─────────────────────────┘
```

### Adapters

pai-lite doesn't run agents — it coordinates whatever you're using:

| Adapter | What it manages | State source |
|---------|-----------------|--------------|
| `agent-duo` | Two agents + orchestrator | `.peer-sync/` |
| `agent-solo` | Coder + reviewer | `.peer-sync/` |
| `claude-code` | Single Claude Code session | tmux/terminal |
| `claude-ai` | Browser conversation | URL bookmark |
| `manual` | Human, no agent | Just notes |

Adapters are simple scripts that:
1. Read state from their source
2. Translate to pai-lite's slot format
3. Optionally expose actions (start, stop, status)

### Triggers

Events that can fire actions:

| Trigger | Mechanism | Example action |
|---------|-----------|----------------|
| Laptop startup | launchd `RunAtLoad` | Morning briefing |
| Repo change | launchd `WatchPaths` or webhook | Update task index |
| Schedule | launchd `StartInterval` | Daily review |
| Manual | CLI command | Sync tasks |

## Directory Structure

### Public repo (`pai-lite`)

```
pai-lite/
├── README.md
├── CLAUDE.md                 # Instructions for AI agents
├── docs/
│   └── ARCHITECTURE.md       # This file
├── bin/
│   └── pai-lite              # Main CLI
├── lib/
│   ├── slots.sh              # Slot management
│   ├── tasks.sh              # Task aggregation
│   └── triggers.sh           # Trigger setup
├── adapters/
│   ├── agent-duo.sh
│   ├── agent-solo.sh
│   ├── claude-code.sh
│   └── claude-ai.sh
└── templates/
    ├── config.example.yaml
    ├── slots.example.md
    └── launchd/              # LaunchAgent plist templates
```

### Private repo (user's choice, e.g., `self-improve`)

```
your-private-repo/
└── harness/
    ├── config.yaml           # Projects, preferences, adapter settings
    ├── slots.md              # Current slot states (6 slots)
    ├── tasks.yaml            # Aggregated task index (generated)
    └── journal/              # Optional daily logs
        └── 2026-01-29.md
```

## State Format

### slots.md

```markdown
# Slots

## Slot 1

**Process:** OCANNL tensor concatenation
**Mode:** agent-duo
**Session:** concat-einsum
**Started:** 2026-01-29T14:00Z

**Terminals:**
- Orchestrator: http://localhost:7680
- Claude: http://localhost:7681
- Codex: http://localhost:7682

**Runtime:**
- Phase: work (round 2)
- Working on: projections inference for `^` operator
- Open question: binding precedence of `^` vs `,`

**Git:**
- Base: ~/repos/ocannl/
- Worktrees: ~/ocannl-concat-einsum-claude/, ~/ocannl-concat-einsum-codex/

---

## Slot 2

**Process:** (empty)

---

## Slot 3

**Process:** ppx-minidebug 3.0 release
**Mode:** claude-code
**Started:** 2026-01-29T10:00Z

**Terminals:**
- Claude Code: tmux session `minidebug`

**Runtime:**
- Finalizing CHANGES.md
- Ready for opam publish

**Git:**
- Branch: release-3.0

---

## Slot 4-6

(empty)
```

### config.yaml

```yaml
# pai-lite configuration

state_repo: lukstafi/self-improve
state_path: harness

slots:
  count: 6
  
projects:
  - name: ocannl
    repo: lukstafi/ocannl
    readme_todos: true
    issues: true
    
  - name: ppx-minidebug
    repo: lukstafi/ppx_minidebug
    issues: true
    
  - name: agent-duo
    repo: lukstafi/agent-duo
    issues: true

  - name: personal
    repo: lukstafi/self-improve
    issues: true  # Chores, reminders

adapters:
  agent-duo:
    enabled: true
  claude-code:
    enabled: true
  claude-ai:
    enabled: true

triggers:
  startup:
    enabled: true
    action: briefing
  sync:
    interval: 3600  # seconds
    action: tasks sync
```

## CLI Interface

```bash
# Task management
pai-lite tasks sync              # Aggregate tasks from all sources
pai-lite tasks list              # Show unified task list
pai-lite tasks show <id>         # Show task details

# Slot management
pai-lite slots                   # Show all slots
pai-lite slot <n>                # Show slot n
pai-lite slot <n> assign <task>  # Assign task to slot
pai-lite slot <n> clear          # Clear slot
pai-lite slot <n> start          # Start agent session (uses adapter)
pai-lite slot <n> stop           # Stop agent session
pai-lite slot <n> note "text"    # Add to runtime notes

# Status
pai-lite status                  # Overview of slots + recent tasks
pai-lite briefing                # Morning briefing

# Setup
pai-lite init                    # Initialize config
pai-lite triggers install        # Install launchd triggers
```

## Integration with agent-duo

The `agent-duo` adapter reads from `.peer-sync/`:

```bash
# adapters/agent-duo.sh

read_session_state() {
    local project_dir="$1"
    local session_name="$2"
    
    local sync_dir="$project_dir/.peer-sync"
    
    # Read ports from session state
    local ports_file="$sync_dir/ports.json"
    
    # Read current phase
    local state_file="$sync_dir/state.json"
    
    # ... translate to slot format
}
```

When agent-duo exposes hooks (future), pai-lite can subscribe:

```bash
# agent-duo emits: session-started, phase-changed, session-ended
# pai-lite adapter listens and updates slot state
```

## Design Principles

1. **Thin layer** — pai-lite coordinates, doesn't replace existing tools
2. **Adapter pattern** — support any orchestrator via simple scripts
3. **Private state** — your data stays in your private repo
4. **Human-in-the-loop** — slots model your attention, not autonomous agents
5. **Git-backed** — everything is version controlled
6. **Offline-first** — works without network (except GitHub sync)
