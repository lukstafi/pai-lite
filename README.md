# pai-lite

A lightweight personal AI infrastructure — a harness for humans working with AI agents. pai-lite manages a small number of concurrent "slots," aggregates tasks from GitHub and READMEs, provides flow-based task views, and wires triggers for briefings and syncs.

## What you get

- **Slots**: 6 ephemeral "CPUs" for active work, not memory or identity.
- **Task index**: unified task list from GitHub issues and README TODOs.
- **Flow engine**: priority/dependency-based views (ready, blocked, critical, impact).
- **Adapters**: thin integrations with existing agent setups (agent-duo, Claude Code, claude.ai, manual).
- **Notifications**: three-tier ntfy.sh integration (strategic, operational, public).
- **Triggers**: launchd/systemd automation for briefings and syncs.

## Installation

```bash
# Clone and install
gh repo clone lukstafi/pai-lite
cd pai-lite
./bin/pai-lite init
```

This installs pai-lite to `~/.local/pai-lite/` with a symlink at `~/.local/bin/pai-lite`, creates a pointer config at `~/.config/pai-lite/config.yaml`, and initializes the harness in your state repo.

If `~/.local/bin` isn't in your PATH, add it to your shell profile:

```bash
export PATH="$PATH:$HOME/.local/bin"
```

### Dependencies

pai-lite requires a few CLI tools for the flow engine:

```bash
# macOS
brew install yq jq

# Ubuntu/Debian
sudo apt install yq jq
```

- `yq` - YAML parsing (mikefarah/yq)
- `jq` - JSON filtering
- `gh` - GitHub CLI (for cloning state repo and fetching issues)

To update pai-lite later, pull the latest changes and run `./bin/pai-lite init` again.

## Quickstart Tutorial

This tutorial walks through setting up pai-lite and using it to manage your work.

### Step 1: Configure your state repository

pai-lite stores state (slots, tasks) in a separate private repository. Edit the pointer config:

```bash
${EDITOR:-vi} ~/.config/pai-lite/config.yaml
```

Set your state repo:

```yaml
state_repo: your-username/your-private-repo
state_path: harness
```

### Step 2: Configure your projects

The full configuration lives in your state repo at `harness/config.yaml`. After the first `pai-lite init`, edit it:

```bash
${EDITOR:-vi} ~/your-private-repo/harness/config.yaml
```

Add the projects you want to track:

```yaml
projects:
  - name: my-project
    repo: your-username/my-project
    readme_todos: true    # Parse TODOs from README
    issues: true          # Fetch GitHub issues

  - name: another-project
    repo: your-username/another-project
    issues: true
```

### Step 3: Sync tasks from your projects

```bash
pai-lite tasks sync
```

This aggregates tasks from GitHub issues and README TODOs into `tasks.yaml`.

### Step 4: Convert to individual task files

For the flow engine to work, convert the aggregated tasks to individual files:

```bash
pai-lite tasks convert
```

This creates one `.md` file per task in `harness/tasks/`, with YAML frontmatter for priority, dependencies, status, etc.

### Step 5: View your task flow

Now you can use the flow engine to see what to work on:

```bash
# What's ready to work on? (sorted by priority)
pai-lite flow ready

# What's blocked and why?
pai-lite flow blocked

# What needs attention? (deadlines, stalled work)
pai-lite flow critical

# What does completing a task unblock?
pai-lite flow impact task-001
```

### Step 6: Assign work to slots

Slots are like CPUs — each one holds one active piece of work:

```bash
# See all slots
pai-lite slots

# Assign a task to slot 1
pai-lite slot 1 assign "Working on task-001: Implement auth"

# Add notes as you work
pai-lite slot 1 note "Completed login form"

# Clear when done
pai-lite slot 1 clear
```

Slot changes auto-commit to your state repo.

### Step 7: Use adapters for agent sessions

If you're using AI agents (agent-duo, Claude Code), adapters can track their state:

```bash
# Start an agent session in slot 2
pai-lite slot 2 assign "task-042 via agent-duo"
pai-lite slot 2 start   # Starts the adapter

# Stop when done
pai-lite slot 2 stop
pai-lite slot 2 clear
```

### Step 8: Get an overview

```bash
# Quick status
pai-lite status

# Full briefing
pai-lite briefing
```

## Configuration

pai-lite uses a two-tier config:

1. **Pointer config** (`~/.config/pai-lite/config.yaml`): minimal, just points to state repo
2. **Full config** (`~/state-repo/harness/config.yaml`): projects, adapters, triggers, notifications

### Example full config

```yaml
state_repo: your-username/private-state
state_path: harness

projects:
  - name: my-app
    repo: your-username/my-app
    readme_todos: true
    issues: true

adapters:
  agent-duo:
    enabled: true
  claude-code:
    enabled: true
  manual:
    enabled: true

triggers:
  startup:
    enabled: true
    action: briefing
  sync:
    enabled: true
    interval: 3600
    action: tasks sync

notifications:
  provider: ntfy
  topics:
    pai: your-username-pai        # Strategic (Mayor)
    agents: your-username-agents  # Operational (workers)
    public: your-username-public  # Public broadcasts
```

## CLI Reference

### Task management

```bash
pai-lite tasks sync              # Aggregate tasks from sources
pai-lite tasks list              # Show unified task list
pai-lite tasks show <id>         # Show task details
pai-lite tasks convert           # Convert to individual task files
pai-lite tasks create <title>    # Create a new task manually
pai-lite tasks files             # List individual task files
```

### Flow engine

```bash
pai-lite flow ready              # Priority-sorted ready tasks
pai-lite flow blocked            # What's blocked and why
pai-lite flow critical           # Deadlines + stalled + high-priority
pai-lite flow impact <id>        # What this task unblocks
pai-lite flow context            # Context distribution across slots
pai-lite flow check-cycle        # Check for dependency cycles
```

### Slot management

```bash
pai-lite slots                   # Show all slots
pai-lite slot <n>                # Show slot n details
pai-lite slot <n> assign <task>  # Assign a task to slot n
pai-lite slot <n> clear          # Clear slot n
pai-lite slot <n> start          # Start agent session (adapter)
pai-lite slot <n> stop           # Stop agent session (adapter)
pai-lite slot <n> note "text"    # Add runtime note to slot n
```

### Notifications

```bash
pai-lite notify pai <msg>        # Send strategic notification
pai-lite notify agents <msg>     # Send operational notification
pai-lite notify public <msg>     # Send public broadcast
pai-lite notify recent [n]       # Show recent notifications
```

### Mayor (autonomous coordinator)

```bash
pai-lite mayor briefing          # Request morning briefing
pai-lite mayor suggest           # Get task suggestions
pai-lite mayor analyze <issue>   # Analyze GitHub issue
pai-lite mayor elaborate <id>    # Elaborate task into detailed spec
pai-lite mayor health-check      # Check for stalled work, deadlines
pai-lite mayor queue             # Show pending requests
```

### Overview and setup

```bash
pai-lite status                  # Overview of slots + tasks
pai-lite briefing                # Morning briefing
pai-lite init                    # Initialize config + harness
pai-lite triggers install        # Install launchd/systemd triggers
pai-lite help                    # Show help
```

## Adapters

Adapters are thin integrations that translate external state into slot format:

| Adapter | Description |
|---------|-------------|
| `agent-duo` | Reads `.peer-sync/` state from agent-duo sessions |
| `agent-solo` | Single-agent mode for agent-duo |
| `claude-code` | Inspects tmux sessions running Claude Code |
| `claude-ai` | Treats bookmarked claude.ai URLs as sessions |
| `chatgpt-com` | Tracks ChatGPT browser sessions |
| `codex` | OpenAI Codex CLI integration |
| `manual` | Track human work without an agent |

## Triggers

Triggers automate periodic actions:

- **macOS**: launchd agents for `startup` and `sync`
- **Linux (Ubuntu)**: systemd user units and timers

Configure in `config.yaml` under `triggers:`. Then run:

```bash
pai-lite triggers install
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design, including:

- Slot model and lifecycle
- Flow engine design
- Mayor (autonomous Claude Opus coordinator)
- Queue-based communication
- Notification tiers

## Development

- Shell scripts are Bash 4+ and designed to be dependency-light.
- Run `shellcheck` on `bin/` and `lib/` during changes.
- State changes to slots auto-commit to the state repo.

## License

MIT
