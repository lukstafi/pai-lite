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
    issues: true          # Fetch GitHub issues

  - name: another-project
    repo: your-username/another-project
    issues: true

triggers:
  watch:
    - paths:
        - ~/repos/my-project/README.md   # Scan for checkboxes/TODOs
      action: tasks sync
```

### Step 3: Sync tasks from your projects

```bash
pai-lite tasks sync
```

This aggregates tasks from GitHub issues and README TODOs into `tasks.yaml`, then automatically converts them to individual `.md` task files in `harness/tasks/` with YAML frontmatter for priority, dependencies, status, etc. The flow engine reads these task files.

### Step 4: Install triggers

Triggers automate Mayor startup and periodic tasks via launchd (macOS) or systemd (Linux). If Mayor is enabled in your config, this also installs a keepalive that starts the Mayor at login and checks every 15 minutes:

```bash
pai-lite triggers install
```

Verify with:

```bash
pai-lite triggers status
```

### Step 5: Get an overview

```bash
# Quick status
pai-lite status

# Full briefing
pai-lite briefing
```

## Configuration

pai-lite uses a two-tier config:

1. **Pointer config** (`~/.config/pai-lite/config.yaml`): minimal, just points to state repo:
   ```yaml
   state_repo: your-username/your-private-repo
   state_path: harness   # optional, defaults to "harness"
   ```
2. **Full config** (`~/state-repo/harness/config.yaml`): projects, adapters, triggers, notifications — once this exists, the pointer config is only used to locate it.

For the full list of options and their defaults, see [`templates/config.example.yaml`](templates/config.example.yaml).

### Example full config

```yaml
state_repo: your-username/private-state
state_path: harness

projects:
  - name: my-app
    repo: your-username/my-app
    issues: true

mayor:
  enabled: true

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
    action: mayor briefing
  sync:
    enabled: true
    interval: 3600
    action: tasks sync
  watch:
    - paths:
        - ~/repos/my-app/README.md
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
pai-lite tasks sync              # Aggregate tasks and convert to task files
pai-lite tasks list              # Show unified task list
pai-lite tasks show <id>         # Show task details
pai-lite tasks convert           # Convert tasks.yaml to task files (also run by sync)
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

### Using skills directly

You don't need Mayor to use pai-lite skills. Clone your harness repository and run Claude Code in the harness directory — skills like `pai-briefing`, `pai-elaborate`, and others work directly. This is useful for read-only tasks (checking status, getting briefings) or when you need something done immediately without waiting for the Mayor queue.

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

- **macOS**: launchd agents for `startup`, `sync`, and Mayor keepalive
- **Linux (Ubuntu)**: systemd user units and timers

If `mayor.enabled` is `true` in your config, `triggers install` also creates a Mayor keepalive service that starts the Mayor at login and checks every 15 minutes.

Configure in `config.yaml` under `triggers:` and `mayor:`. Then run:

```bash
pai-lite triggers install
```

## Multi-machine setup

pai-lite supports running across multiple machines. All state lives in a git repository, so any machine with access can read slots, tasks, and flow views. For coordinating Mayor (so only one instance runs at a time), pai-lite provides federation with Tailscale networking.

### How it works

- **Git-backed state**: every machine clones the same harness repo. Pull to see the latest state, push to share yours.
- **Tailscale networking**: optional MagicDNS-based hostname resolution for cross-machine URLs. Configure `network.mode: tailscale` in your harness config.
- **Seniority-based leader election**: nodes are listed in your config in priority order. The highest-priority node with a fresh heartbeat (< 15 min) becomes the Mayor leader. If the leader goes offline, the next node takes over automatically.
- **Heartbeats**: each node publishes a heartbeat every 5 minutes to `federation/heartbeats/`. The federation trigger handles this.

### Typical deployment

An always-on machine (e.g., Mac Mini) runs Mayor 24/7 via launchd, while your laptop pulls state via git and runs worker slots. Any machine can also run pai-lite skills directly by opening Claude Code in the harness directory.

### Federation commands

```bash
pai-lite network status              # Show network configuration
pai-lite federation status           # Show leader, nodes, heartbeats
pai-lite federation tick             # Publish heartbeat + run election
pai-lite federation elect            # Run leader election only
pai-lite federation heartbeat        # Publish heartbeat only
```

Enable federation in your harness `config.yaml`:

```yaml
network:
  mode: tailscale
  nodes:
    - name: mac-mini
      tailscale_hostname: mac-mini.tailnet-name.ts.net
    - name: macbook
      tailscale_hostname: macbook.tailnet-name.ts.net

triggers:
  federation:
    enabled: true
    interval: 300
    action: federation tick
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design, including:

- Slot model and lifecycle
- Flow engine design
- Mayor (autonomous Claude Opus coordinator)
- Queue-based communication
- Notification tiers
- Multi-machine federation and deployment

## Development

- Shell scripts are Bash 4+ and designed to be dependency-light.
- Run `shellcheck` on `bin/` and `lib/` during changes.
- State changes to slots auto-commit to the state repo.

## License

MIT
