# pai-lite

A lightweight personal AI infrastructure — a harness for humans working with AI agents. pai-lite manages a small number of concurrent “slots,” aggregates tasks from GitHub and READMEs, and wires triggers for briefings and syncs.

## What you get

- **Slots**: 6 ephemeral “CPUs” for active work, not memory or identity.
- **Task index**: unified task list from GitHub issues and README TODOs.
- **Adapters**: thin integrations with existing agent setups (agent-duo, Claude Code, claude.ai).
- **Triggers**: launchd/systemd automation for briefings and syncs.

## Installation

```bash
# Clone and install
gh repo clone lukstafi/pai-lite
cd pai-lite
./bin/pai-lite init
```

This installs `pai-lite` to `~/.local/bin/` and creates the initial config. If `~/.local/bin` isn't in your PATH, add it to your shell profile:

```bash
export PATH="$PATH:$HOME/.local/bin"
```

To update pai-lite later, pull the latest changes and run `./bin/pai-lite init` again.

## Quickstart

After installation:

```bash
# 1) Edit config
${EDITOR:-vi} ~/.config/pai-lite/config.yaml

# 2) Sync tasks
pai-lite tasks sync

# 3) See slots + tasks
pai-lite status
```

## Configuration

- Default config path: `~/.config/pai-lite/config.yaml`
- State lives in your private repo under `state_path` (default `harness/`)
- pai-lite will clone the private state repo into your home directory via `gh` if it is missing

See `templates/config.example.yaml` and `templates/harness/config.yaml` for examples.

## CLI

```bash
# Task management
pai-lite tasks sync
pai-lite tasks list
pai-lite tasks show <id>

# Slot management
pai-lite slots
pai-lite slot <n>
pai-lite slot <n> assign <task>
pai-lite slot <n> clear
pai-lite slot <n> start
pai-lite slot <n> stop
pai-lite slot <n> note "text"

# Overview and setup
pai-lite status
pai-lite briefing
pai-lite init
pai-lite triggers install
```

## Adapters

Adapters are thin, read-only integrations that translate external state into slot format.
- `agent-duo`: reads `.peer-sync/` state and ports
- `claude-code`: inspects tmux sessions
- `claude-ai`: treats bookmarked URLs as sessions

## Triggers

- **macOS**: launchd agents for `startup` and `sync`
- **Linux (Ubuntu)**: systemd user units and timers

Configure in `config.yaml` under `triggers:`. Then run:

```bash
pai-lite triggers install
```

## Development

- Shell scripts are Bash 4+ and designed to be dependency-light.
- Run `shellcheck` on `bin/` and `lib/` during changes.

## License

MIT
