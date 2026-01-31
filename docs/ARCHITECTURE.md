# pai-lite Architecture

*Design document — describes the target architecture, not necessarily the current implementation.*

## Overview

pai-lite is a lightweight personal AI infrastructure — a harness for humans working with AI agents. It manages concurrent agent sessions (slots), orchestrates autonomous task analysis (the Mayor), and maintains flow-based task management.

**Core philosophy: "Autonomy babysitting automation"**
- **Autonomous layer**: AI agents make strategic decisions (Mayor, workers)
- **Automation layer**: Deterministic scripts execute reliably (triggers, adapters, sync)
- The autonomous layer supervises; the automation layer provides predictable, deterministic behavior.

## Architectural Layers

```
┌────────────────────────────────────────────────────────────┐
│              THE MAYOR (Autonomous - Lifelong)             │
│         Claude Opus 4.5 in Claude Code (tmux/ttyd)         │
│                                                            │
│  Invoked by automation when AI judgment needed:            │
│  • Analyze GitHub issues → create task files               │
│  • Generate strategic briefings                            │
│  • Detect stalled work                                     │
│  • Suggest next tasks based on flow state                  │
│                                                            │
│  Uses native Claude Code capabilities:                     │
│  • Task tool → Haiku/Sonnet subagents for fast tasks       │
│  • OCaml binaries for deterministic algorithms             │
│  • Skills with embedded delegation patterns                │
│                                                            │
│  Writes decisions to git-backed state (persistent)         │
└────────────┬───────────────────────────────────────────────┘
             │ supervises
             ▼
┌────────────────────────────────────────────────────────────┐
│           AUTOMATION LAYER (Deterministic - Always On)     │
│                                                            │
│  Flow Engine (Bash + OCaml):                               │
│    • Maintains dependency graph (OCaml: type-safe)         │
│    • Computes ready queue (deterministic filtering)        │
│    • Detects deadline violations (date math)               │
│                                                            │
│  Trigger System (launchd):                                 │
│    • 08:00 → invoke Mayor for briefing                     │
│    • Every 4h → slot health check                          │
│    • WatchPaths → repo changed, sync tasks                 │
│                                                            │
│  Adapter Monitors (Bash polling):                          │
│    • Read .peer-sync/ → update slot state                  │
│    • Detect phase changes → log to journal                 │
│                                                            │
│  State Sync (git):                                         │
│    • Pull from repos → aggregate issues                    │
│    • Commit Mayor's changes                                │
│    • Push to private repo                                  │
│                                                            │
│  Notifications (ntfy.sh):                                  │
│    • <user>-pai: Mayor strategic updates (private)         │
│    • <user>-agents: Worker task events (private)           │
│    • <user>-public: Milestone broadcasts (read-only)       │
└────────────┬───────────────────────────────────────────────┘
             │ manages
             ▼
┌────────────────────────────────────────────────────────────┐
│              WORKER SLOTS (Ephemeral AI)                   │
│                     6 slots (hardcoded)                    │
│                                                            │
│  Slot 1: agent-duo on task-042 (coder + reviewer)          │
│  Slot 2: empty                                             │
│  Slot 3: claude-code on task-089                           │
│  Slot 4-6: empty                                           │
│                                                            │
│  Workers implement tasks, not strategy                     │
└────────────────────────────────────────────────────────────┘
```

## Core Concepts

### The Mayor: Autonomous Coordinator

The **Mayor** is a persistent Claude Code instance running in a dedicated tmux session (`pai-mayor`). It provides autonomous strategic thinking while the automation layer handles reliable execution.

**What the Mayor does (Claude Opus 4.5):**
- Analyzes GitHub issues for actionability and dependencies (context understanding)
- Generates morning briefings with strategic suggestions (writing, wisdom)
- Detects stalled work (tasks in-progress >7 days with no updates)
- Suggests what to work on next based on priority, deadlines, and dependencies
- Elaborates high-level tasks into detailed Markdown specifications (SWE tasks)
- Publishes curated updates to public notification channel

**What the Mayor delegates:**

*Via Task tool (native Claude Code subagents):*
- **Haiku**: Fast extraction, parsing, simple validation
- **Sonnet**: Medium-complexity tasks, structured generation

*Via OCaml binaries (deterministic algorithms):*
- Dependency graph computation
- Cycle detection, topological sort
- Priority queue management
- Schedule validation

The Mayor's skills (defined in the framework) can embed delegation patterns, e.g., a `/analyze-issue` skill that uses a Haiku subagent for dependency extraction before the Mayor writes the task file.

**How automation invokes the Mayor:**
```bash
# Trigger at 08:00 (launchd)
tmux send-keys -t pai-mayor "/briefing" C-m
# Mayor writes to briefing.md
# Automation reads and notifies

# New issue detected
tmux send-keys -t pai-mayor "/analyze-issue ocannl 127" C-m
# Mayor creates task-143.md with inferred dependencies

# User asks for suggestions
tmux send-keys -t pai-mayor "/suggest" C-m
# Mayor analyzes flow state, writes suggestions
```

**Why one lifelong Mayor (not multiple specialized agents)?**
- Builds institutional memory (learns patterns, preferences)
- Consistent decision-making across analysis, scheduling, briefing
- Can see connections across projects
- Simpler mental model (one AI coordinates pai-lite)

**Why Claude Opus 4.5 for Mayor?**
- **Well-rounded judgment** — strategic thinking over raw benchmark optimization
- **Strong SWE skills** — task elaboration, detailed specifications
- **Better writer** — briefings, narratives, contextual understanding
- **Infrequent invocations** — cost is acceptable for morning briefings, issue analysis

**Why Opus over Sonnet for Mayor?**
- Mayor needs **institutional memory** and nuanced judgment
- Briefings require **depth** over speed
- Strategic decisions benefit from more capable reasoning
- Cost is manageable since Mayor runs infrequently

**When Haiku/Sonnet subagents make sense:**
- Fast extraction tasks (parsing dependencies from prose)
- Structured output generation
- Lightweight validation checks
- Any task where latency matters more than depth

### Delegation Strategy

The Mayor uses **Claude Code's native Task tool** for delegation, not custom API wrappers:

| Task | Approach | Why |
|------|----------|-----|
| Extract dependencies from prose | Task → Haiku | Fast, cheap, sufficient |
| Structured output generation | Task → Sonnet | Better format adherence |
| Graph algorithms | OCaml binary | Deterministic, type-safe |
| Schedule validation | OCaml binary | Provably correct |
| Strategic analysis | Mayor (Opus) | Needs judgment, context |
| Writing briefings | Mayor (Opus) | Needs narrative skill |

**Example: `/analyze-issue` skill**
```
1. [Opus] Read issue, assess actionability
   └─ Not actionable → return early

2. [Task → Haiku] Extract structured data
   "Return JSON: {blocks: [...], blocked_by: [...]}"
   └─ Fast extraction

3. [Bash] pai_flow check-cycle <dependencies>
   └─ OCaml validates no circular deps

4. [Opus] Write task file with context
```

Skills defined in the framework embed these patterns, keeping the Mayor's prompts clean.

### The Slot Model: Forcing Function for Parallelization

pai-lite hardcodes **6 slots** (not configurable) based on cognitive science and forcing functions.

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

**Why exactly 6 slots (hardcoded)?**

1. **Cognitive science**: Human working memory holds roughly 4–7 items. Six slots sits at the upper bound of focused attention.

2. **Forcing function**: Fixed capacity creates pressure to parallelize.
   - "I have 6 slots. 2 are active. 4 are idle."
   - "That's wasteful. What else should I parallelize?"
   - The constraint drives the behavior.

3. **Like Kanban WIP limits**: If configurable, you'd bikeshed ("4 or 8 slots today?") instead of working. The constraint is the feature.

4. **You don't have to use all slots**: Having 6 defined with 2 active is fine. The empty slots create pressure, not waste.

**Key properties:**
- Slots have no persistent identity — slot 3 isn't "the OCANNL slot"
- Context switching has a cost (like real CPUs)
- Runtime state is lost when the slot is cleared
- The work itself persists (commits, task files) — only the "registers" are ephemeral

### Flow-Based Task Management

pai-lite uses **flow-based scheduling** (throughput over latency), not time-based scheduling (org-mode's SCHEDULED dates).

**What matters:**
- ✅ **Dependencies**: What blocks what (can't start B until A is done)
- ✅ **Hard deadlines**: External events only (paper due Feb 14, conference Mar 20)
- ✅ **Priority**: A (critical) / B (important) / C (nice-to-have)
- ✅ **Readiness**: Is `blocked_by` empty? Can we start now?
- ✅ **Status**: `ready` → `in-progress` → `done`
- ✅ **Effort**: Small / medium / large (for WIP balancing, not time estimates)
- ✅ **Context**: Tags for minimizing context switches

**What doesn't matter (for most tasks):**
- ❌ **SCHEDULED dates**: Arbitrary "work on this Tuesday" creates false pressure
- ❌ **Time estimates**: "This will take 3 hours" is unknowable and creates anxiety
- ❌ **Calendar agenda views**: "What's scheduled today" vs "What's ready to start"

**Exception — recurring tasks:** Some work genuinely recurs (weekly reviews, monthly reports). These can be modeled as tasks with a `recurrence` field that generates new ready tasks when completed.

**Why flow-based?**
- Research and development is about **throughput** (completing valuable work over time), not **latency** (hitting arbitrary timestamps)
- Deadlines only matter when external (paper submissions, conferences, releases)
- Work flows based on readiness and priority, not calendar dates
- Focus on "What can I work on now?" not "What did I schedule for 2pm?"

**Task representation:**
```yaml
---
id: task-042
title: "Implement tensor concatenation with einsum notation"
project: ocannl
status: in-progress        # blocked | ready | in-progress | done | abandoned
priority: A                # A (critical) | B (important) | C (nice-to-have)
deadline: 2026-05-15       # ONLY for hard external deadlines
dependencies:
  blocks: [task-043, task-044]
  blocked_by: []           # Empty = ready to start
effort: large              # small | medium | large
context: einsum            # For minimizing context switches
slot: 1                    # Currently assigned slot (or null)
adapter: agent-duo
created: 2026-01-29
started: 2026-01-29
completed: null
github_issue: 127
---

# Context
Roadmap item: Support `^` operator for tensor concatenation...

# Current State
- [x] Parse `^` in einsum expressions
- [ ] Implement projection inference  ← currently here
- [ ] Add tests for edge cases

# Blockers
None - ready to continue

# Notes
2026-01-31: Discussed binding precedence, decided on...
```

### Flow Views (Not Calendar Agenda)

Instead of org-mode's calendar-based agenda, pai-lite provides **flow views**:

```bash
# What can I work on right now?
pai-lite flow ready
# → Priority-sorted list of tasks where blocked_by is empty

# What's blocking progress?
pai-lite flow blocked
# → Dependency graph of blocked tasks and their blockers

# What needs urgent attention?
pai-lite flow critical
# → Approaching deadlines + stalled work + high-priority ready tasks

# What happens if I finish this?
pai-lite flow impact task-042
# → Shows downstream tasks that would unblock

# Am I context-switching too much?
pai-lite flow context
# → Shows context distribution across active slots
```

**Mayor's flow analysis (OCaml pseudocode):**
```ocaml
(* Suggestion logic: what to work on next *)
let suggest_next_task slots tasks =
  let ready = tasks |> List.filter (fun t ->
    t.blocked_by = [] && t.status = Ready) in

  (* Priority 1: Hard deadlines approaching *)
  let urgent = ready |> List.filter (fun t ->
    Option.is_some t.deadline && days_until t.deadline < 30) in
  match List.sort by_priority_then_deadline urgent with
  | t :: _ -> Some t
  | [] ->

  (* Priority 2: High-impact (unblocks many tasks) *)
  let high_impact = ready |> List.filter (fun t ->
    count_blocked_tasks t >= 3) in
  match List.sort by_priority_then_impact high_impact with
  | t :: _ -> Some t
  | [] ->

  (* Priority 3: Same context as active slots *)
  let active_contexts = slots
    |> List.filter_map (fun s -> Option.map (fun t -> t.context) s.task)
    |> StringSet.of_list in
  let same_context = ready |> List.filter (fun t ->
    StringSet.mem t.context active_contexts) in
  match List.sort by_priority same_context with
  | t :: _ -> Some t
  | [] ->

  (* Priority 4: Highest priority ready task *)
  List.sort by_priority ready |> List.hd_opt
```

### Three-Tier Notification System

pai-lite uses **ntfy.sh** with three reserved topics:

```
┌─────────────────────────────────────────────────────┐
│ <user>-agents (PRIVATE - Reserved)                  │
│ Detailed worker execution, internal state           │
├─────────────────────────────────────────────────────┤
│ • Slot 1: agent-duo phase → work                    │
│ • Slot 3: build failed - type errors                │
│ • Slot 2: merge conflict needs resolution           │
│ • Slot 1: PR draft ready, waiting for review        │
│                                                     │
│ Audience: You only                                  │
│ Volume: High (event-driven)                         │
│ Detail: Technical, debugging-level                  │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ <user>-pai (PRIVATE - Reserved)                     │
│ Strategic coordination, private planning            │
├─────────────────────────────────────────────────────┤
│ • Morning briefing: 2 high-priority tasks ready     │
│ • POPL paper deadline in 2 days!                    │
│ • task-042 completed → 3 tasks unblocked            │
│ • Detected: task-089 stalled for 10 days            │
│                                                     │
│ Audience: You only                                  │
│ Volume: Medium (periodic + alerts)                  │
│ Detail: Strategic, decision-focused                 │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ <user>-public (PUBLIC - Read-only Reserved)         │
│ Project milestones, availability, collaboration     │
├─────────────────────────────────────────────────────┤
│ • OCANNL v2.1 released with einsum improvements     │
│ • New blog post: "Tensor Concat Internals"          │
│ • Talk accepted: ML Workshop 2026                   │
│ • Deep focus: working on POPL paper this week       │
│                                                     │
│ Audience: Anyone (colleagues, collaborators, public)│
│ Volume: Low (curated milestones)                    │
│ Detail: High-level, externally relevant             │
│ Access: READ ONLY (only you can publish)            │
└─────────────────────────────────────────────────────┘
```

**Why read-only public?**
- ntfy is for push notifications (ephemeral), not bidirectional communication
- Human feedback should go through proper channels (email, GitHub Issues/Discussions)
- Prevents notification pollution (unbounded public input defeats the purpose)
- Keeps your notification stream under control (the whole point of pai-lite)

**ntfy.sh topic security:**
The `<user>-*` topic names shown here assume **reserved topics** via an ntfy.sh subscription. Without a subscription, ntfy.sh topics are globally namespaced — anyone who guesses the name can subscribe. Options for users without subscriptions:
- Use random suffixes (e.g., `lukstafi-pai-a7x9k2`)
- Self-host ntfy (simple Docker deployment)
- Use alternative notification providers

### Adapters

pai-lite doesn't run agents — it coordinates whatever you're using:

| Adapter | What it manages | State source |
|---------|-----------------|--------------|
| `agent-duo` | Two agents + orchestrator | `.peer-sync/` |
| `agent-solo` | Coder + reviewer | `.peer-sync/` |
| `claude-code` | Single Claude Code session | tmux/terminal |
| `claude-ai` | Browser conversation | URL bookmark |
| `manual` | Human, no agent | Just notes |

Adapters are simple Bash scripts that:
1. Read state from their source
2. Translate to pai-lite's slot format
3. Optionally expose actions (start, stop, status)

### Triggers

Events that fire automation:

| Trigger | Mechanism | Example action |
|---------|-----------|----------------|
| Morning | launchd `StartCalendarInterval` | Invoke Mayor for briefing |
| Periodic | launchd `StartInterval` | Health check, flow analysis |
| Repo change | launchd `WatchPaths` | Sync tasks, analyze issues |
| Manual | CLI command | User-initiated |

## Implementation: Hybrid Bash + OCaml

pai-lite uses **Bash for coordination**, **OCaml for complex logic**:

```
Bash (coordination layer):
├─ bin/pai-lite              CLI entry, arg parsing, dispatch
├─ lib/triggers.sh           launchd integration
├─ lib/slots.sh              tmux/adapter orchestration
├─ adapters/*.sh             Read .peer-sync/, git, tmux
└─ Simple glue, process orchestration

OCaml (logic layer):
├─ pai_flow.exe              Dependency graph (basic algorithms)
├─ pai_schedule.exe          Priority queuing, filtering
├─ pai_parse.exe             Task frontmatter parsing
└─ Type-safe data structures, deterministic algorithms

GPT-5.2 (delegated for complex reasoning):
├─ Low-effort mode           Parsing, extraction, validation
└─ High-effort mode          Complex optimization, proofs, hard algorithms
```

**Why Bash for coordination?**
- ✅ Native language of Unix automation (tmux, git, launchd, curl)
- ✅ No compilation step (edit and run immediately)
- ✅ Transparent (just read the script)
- ✅ Minimal dependencies (works anywhere)
- ✅ Perfect for glue code (pipes, redirects, subshells)

**Why OCaml for logic?**
- ✅ Type safety for complex algorithms (dependency graphs, scheduling)
- ✅ Pattern matching for state machines (task status transitions)
- ✅ Your primary language (dogfooding, expertise)
- ✅ Fast execution (compiled, no startup latency)
- ✅ Can extract reusable libraries for OCaml community

**Why NOT Python?**
- ❌ Runtime errors that OCaml catches at compile time
- ❌ Slower startup (matters for frequent CLI invocations)
- ❌ OCaml is the author's primary language (expertise, dogfooding)

**Example integration:**
```bash
# Bash wrapper (bin/pai-lite)
case "$1" in
    flow)
        # Call OCaml for graph computation
        pai_flow_engine "$2" "$STATE_PATH/tasks/"
        ;;
    briefing)
        # Orchestrate: invoke Mayor (Claude), format, notify
        tmux send-keys -t pai-mayor "/briefing" C-m
        wait_for_completion
        cat "$STATE_PATH/briefing.md"
        notify-pai "$(head -5 $STATE_PATH/briefing.md)" 3 "Briefing"
        ;;
esac
```

## Directory Structure

### Public repo (`pai-lite`)

```
pai-lite/
├── README.md
├── CLAUDE.md                      # Instructions for AI agents
├── docs/
│   ├── ARCHITECTURE.md            # This file
│   └── ADAPTERS.md
├── bin/
│   └── pai-lite                   # Main CLI (Bash)
├── lib/
│   ├── slots.sh                   # Slot management (Bash)
│   ├── tasks.sh                   # Task aggregation (Bash)
│   ├── triggers.sh                # Trigger setup (Bash)
│   └── notify.sh                  # ntfy.sh integration (Bash)
├── adapters/
│   ├── agent-duo.sh
│   ├── agent-solo.sh
│   ├── claude-code.sh
│   └── claude-ai.sh
├── pai_flow/                      # OCaml dependency analysis
│   ├── dune
│   ├── flow.ml
│   └── graph.ml
├── pai_schedule/                  # OCaml scheduling logic
│   ├── dune
│   └── schedule.ml
└── templates/
    ├── config.example.yaml
    ├── slots.example.md
    └── launchd/                   # LaunchAgent plist templates
```

### Private repo (user's choice, e.g., `self-improve`)

```
your-private-repo/
└── harness/
    ├── config.yaml                # Projects, Mayor settings, notification topics
    ├── slots.md                   # Current slot states (6 slots, always)
    ├── agenda.md                  # Generated flow view (not calendar)
    ├── tasks/                     # Task tree (git-backed)
    │   ├── task-001.md
    │   ├── task-002.md
    │   └── ...
    ├── graph.dot                  # Generated dependency graph
    ├── journal/                   # Daily logs
    │   └── 2026-01-31.md
    └── mayor/                     # Mayor's persistent state
        ├── context.md             # Current understanding
        ├── tools/
        │   ├── gpt-low            # GPT-5.2 low-reasoning mode
        │   ├── gpt-high           # GPT-5.2 high-reasoning mode
        │   ├── notify             # ntfy.sh wrapper
        │   └── dependency-extract # GPT-powered extraction
        └── memory/                # Long-term patterns
            └── user-preferences.md
```

## State Format

### slots.md

```markdown
# Slots

## Slot 1

**Process:** OCANNL tensor concatenation
**Task:** task-042
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
**Task:** task-089
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

# Slots are hardcoded to 6 (not configurable)
# This is a forcing function, not a limitation

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

mayor:
  enabled: true
  backend: tmux-ttyd           # Similar setup to agent-duo
  session: pai-mayor
  ttyd_port: 7690              # Web terminal access

  # Delegation uses Claude Code's native Task tool
  # Skills can specify subagent model (haiku, sonnet) as needed
  # No external API configuration required

  autonomy_level:
    analyze_issues: auto        # Auto creates task files
    elaborate_tasks: auto        # Auto writes detailed specs
    infer_dependencies: auto     # Auto adds blocks/blocked-by
    suggest_priorities: suggest  # Suggests, doesn't set
    assign_to_slots: manual      # Requires approval
    start_sessions: manual       # Requires approval

  schedule:
    briefing: "08:00"
    health_check: "every 4h"
    analyze_repos: "on_change"   # WatchPaths trigger

notifications:
  provider: ntfy
  topics:
    pai: lukstafi-pai           # Private strategic (Mayor)
    agents: lukstafi-agents     # Private operational (workers)
    public: lukstafi-public     # Public read-only (broadcasts)

  priorities:
    briefing: 3
    health_check: 3
    deadline_7days: 4
    deadline_3days: 5
    stall_detected: 4
    critical_alert: 5

  public_filter:
    # What gets auto-published to lukstafi-public
    auto_publish:
      - release_completed
      - paper_accepted
      - talk_accepted

    # Never publish automatically
    never_publish:
      - debugging_info
      - private_deadlines
      - internal_tasks
      - slot_states

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
pai-lite tasks list              # Show all tasks
pai-lite tasks show <id>         # Show task details

# Flow views (not calendar-based)
pai-lite flow ready              # Priority-sorted ready tasks
pai-lite flow blocked            # What's blocked and why
pai-lite flow critical           # Deadlines + stalled + high-priority
pai-lite flow impact <id>        # What this task unblocks
pai-lite flow context            # Context distribution

# Slot management (always 6 slots)
pai-lite slots                   # Show all slots
pai-lite slot <n>                # Show slot n (1-6)
pai-lite slot <n> assign <task>  # Assign task to slot
pai-lite slot <n> clear          # Clear slot
pai-lite slot <n> start          # Start agent session (uses adapter)
pai-lite slot <n> stop           # Stop agent session
pai-lite slot <n> note "text"    # Add to runtime notes

# Mayor interaction
pai-lite mayor briefing          # Generate strategic briefing
pai-lite mayor suggest           # Get task suggestions
pai-lite mayor analyze <issue>   # Analyze GitHub issue
pai-lite mayor elaborate <id>    # Elaborate task into detailed spec
pai-lite mayor health-check      # Scan for stalled work, deadlines

# Status
pai-lite status                  # Overview of slots + flow state
pai-lite briefing                # Morning briefing (invokes Mayor)

# Setup
pai-lite init                    # Initialize config
pai-lite triggers install        # Install launchd triggers
```

## Deployment Options

### Option 1: Laptop (Simple Start)

**Good for:**
- Initial prototyping
- Works when laptop is awake
- Simple setup

**Limitations:**
- Briefing only happens if laptop awake at 8am
- No continuous monitoring when lid closed
- No background analysis while you sleep

**Setup:**
```bash
# Mayor runs in tmux on laptop
tmux new-session -s pai-mayor -d -c ~/repos/self-improve/harness/mayor
tmux send-keys -t pai-mayor "claude" C-m

# launchd triggers (when laptop awake)
pai-lite triggers install
```

### Option 2: Dedicated Always-On Machine (Full Autonomy)

**Good for:**
- True 24/7 operation
- Morning briefing works even if laptop asleep
- Continuous repo monitoring
- Background health checks

**Options:**
- Mac Mini (can run macOS, launchd, tmux natively)
- Linux server (home server, VPS, NUC)
- Raspberry Pi (if Claude Code supports ARM)

**Architecture:**
```
Mac Mini (always-on):
  • Mayor (Claude Code in tmux)
  • Automation layer (launchd triggers)
  • Git sync (pulls/pushes to self-improve)
  • Notifications sent to phone

Your Laptop (work machine):
  • pai-lite CLI (reads git state)
  • Worker slots (agent-duo, claude-code)
  • Can SSH to Mac Mini to check Mayor
```

**State flow:**
1. Mac Mini's Mayor analyzes repos at 7am → writes to git
2. Mac Mini pushes to GitHub
3. Your laptop pulls when you start work → sees Mayor's analysis
4. You work in slots on laptop → updates slots.md
5. Laptop pushes to git → Mac Mini syncs and monitors

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
    local orch_port=$(jq -r '.orchestrator' "$ports_file")
    local claude_port=$(jq -r '.claude' "$ports_file")
    local codex_port=$(jq -r '.codex' "$ports_file")

    # Read current phase
    local state_file="$sync_dir/state.json"
    local phase=$(jq -r '.phase' "$state_file")

    # Translate to slot format
    echo "**Terminals:**"
    echo "- Orchestrator: http://localhost:$orch_port"
    echo "- Claude: http://localhost:$claude_port"
    echo "- Codex: http://localhost:$codex_port"
    echo ""
    echo "**Runtime:**"
    echo "- Phase: $phase"
}

# Notify on phase changes
watch_phase_changes() {
    local prev_phase=""
    while true; do
        phase=$(jq -r '.phase' "$sync_dir/state.json")
        if [ "$phase" != "$prev_phase" ]; then
            notify-agent "$slot" "Phase changed: $prev_phase → $phase" 3
            prev_phase="$phase"
        fi
        sleep 5
    done
}
```

## Design Principles

1. **Autonomy babysitting automation** — AI makes decisions, deterministic scripts execute reliably

2. **Flow-based, not time-based** — Throughput over latency, dependencies over deadlines

3. **Thin coordination layer** — pai-lite coordinates, doesn't replace existing tools

4. **Adapter pattern** — Support any orchestrator via simple scripts

5. **Private state, public broadcasts** — Data in private repo, curated milestones to public

6. **Git-backed persistence** — Everything version controlled, survives agent crashes

7. **Hardcoded constraints as forcing functions** — 6 slots create pressure to parallelize

8. **Hybrid implementation** — Bash for glue, OCaml for algorithms, no Python

9. **One lifelong Mayor** — Builds memory, consistent decisions, sees cross-project connections

10. **Notifications are outputs, not inputs** — ntfy for push alerts, email/GitHub for human communication

## Failure Modes and Recovery

The automation layer is deterministic but not infallible. Here's how pai-lite handles failures:

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Mayor crashes mid-analysis | tmux session exits, launchd notices | Restart Mayor; git state is last-committed |
| Git sync conflict | `git pull` fails | Notify user; manual resolution required |
| launchd trigger doesn't fire | Health check detects stale state | User runs `pai-lite triggers check` |
| ntfy.sh unreachable | curl returns error | Log locally; retry on next trigger |
| Claude API down | Task tool fails | Mayor retries or skips delegation, logs warning |
| Task file corrupted | OCaml parser fails | Notify user; task excluded from flow until fixed |

**Design for recovery:**
- All state changes go through git → crash-safe, auditable
- Mayor writes atomically (temp file → rename)
- Adapters are stateless readers (can restart anytime)
- Triggers are idempotent (safe to re-run)

**What requires manual intervention:**
- Git merge conflicts (by design — human resolves semantic conflicts)
- Slot assignment (configurable: manual vs. auto with approval)
- Starting agent sessions (configurable: manual vs. auto with approval)

## Typical Day in the Life

```
07:00 - Automation syncs repos (if on always-on machine)
  launchd WatchPaths detects changes
  Bash: git pull ocannl, ppx_minidebug
  Bash: parse new issues → new-issues.json

07:05 - Mayor analyzes new issues
  Automation: tmux send-keys -t pai-mayor "/analyze new-issues.json"
  Mayor (Opus): reads issues with context, understands implications
  Mayor: Task → Haiku extracts dependencies as JSON
  Mayor: creates task-143.md with context, acceptance criteria, code pointers
  Mayor: git commit, push

08:00 - Morning briefing
  launchd: triggers briefing
  Automation: tmux send-keys -t pai-mayor "/briefing"
  Mayor (Opus): reads slots.md, tasks/, understands context
  OCaml: pai_flow_engine ready tasks/ (computes ready queue, priorities)
  Mayor: writes briefing.md with strategic suggestions
  Automation: ntfy.sh/lukstafi-pai priority 3 "Briefing ready"
  You: read on phone when you wake up

09:00 - Start work (on laptop)
  You: pai-lite flow ready
  OCaml: computes ready queue
  Bash: formats, displays: task-101 (A, deadline 7 days), task-067 (A)...

  You: pai-lite slot 1 assign task-101
  Bash: updates slots.md, git commit, push

  You: pai-lite slot 1 start
  Bash: calls adapters/agent-duo.sh start 1
  agent-duo starts, writes to .peer-sync/
  Bash: ntfy.sh/lukstafi-agents "Slot 1: agent-duo started"

12:00 - Periodic health check
  launchd: triggers every 4h
  Automation: tmux send-keys -t pai-mayor "/health-check"
  Mayor: scans tasks in-progress
  Mayor: detects task-089 stalled (14 days, no updates)
  Mayor: ntfy.sh/lukstafi-pai priority 4 "task-089 stalled 14 days"

14:30 - Slot completes PR
  agent-duo: phase → pr-ready
  Bash: detects phase change (polling .peer-sync/)
  Bash: ntfy.sh/lukstafi-agents priority 4 "Slot 1: PR ready"

15:00 - You merge PR, task completes
  You: pai-lite slot 1 clear
  Bash: updates slots.md, task-101.md (status: done)
  Bash: git commit, push

  Mayor (next check): sees task-101 done
  OCaml: recomputes dependency graph, identifies newly unblocked tasks
  Mayor (Opus): writes notification with context and strategic insight
  Mayor: ntfy.sh/lukstafi-pai "task-101 done → 2 tasks unblocked, suggests 102 first"

  Mayor: checks if task-101 tagged "release"
  Mayor: yes! Auto-publish to lukstafi-public
  Mayor: ntfy.sh/lukstafi-public priority 4 "OCANNL v2.1 released"

Evening - You check flow state
  You: pai-lite briefing
  Mayor: generates end-of-day summary
  Displays: 1 task completed, 2 newly ready, 4 slots idle, 1 deadline in 6 days
```

This architecture creates a **self-sustaining AI infrastructure** that amplifies your research productivity while maintaining human control through configurable autonomy levels and approval gates.
