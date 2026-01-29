# CLAUDE.md

Instructions for AI agents working on this repository.

## Project Overview

pai-lite is a lightweight personal AI infrastructure — a harness for humans working with AI agents. It manages concurrent agent sessions (slots), aggregates tasks, and triggers actions on events.

## Key Concepts

- **Slots**: Like CPUs, not memory. Each slot runs one process, holds runtime state, has no persistent identity.
- **Adapters**: Thin integrations with different agent systems (agent-duo, Claude Code, etc.)
- **State**: Stored in a separate private repo, not here. This repo is public tooling only.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for full details.

## Code Style

- Shell scripts (Bash 4+)
- POSIX-compatible where possible
- Clear error messages
- Minimal dependencies

## Directory Structure

```
pai-lite/
├── bin/pai-lite          # Main CLI entry point
├── lib/                  # Core functionality
│   ├── slots.sh
│   ├── tasks.sh
│   └── triggers.sh
├── adapters/             # Integration with different agent systems
└── templates/            # Example configs, launchd plists
```

## Testing

When making changes:
1. Test with `shellcheck` for shell script issues
2. Test locally with a mock config before pushing
3. Ensure adapters fail gracefully when their target isn't available

## Common Tasks

### Adding an adapter

1. Create `adapters/<name>.sh`
2. Implement: `adapter_<name>_read_state()`, `adapter_<name>_start()`, `adapter_<name>_stop()`
3. Document in `docs/ADAPTERS.md`

### Adding a trigger type

1. Add to `lib/triggers.sh`
2. Create template plist in `templates/launchd/` if launchd-based
3. Update `pai-lite triggers install`

## Important Notes

- Never store user data in this repo — all state goes to the user's private repo
- Keep dependencies minimal
- Prefer reading state from existing sources (like agent-duo's `.peer-sync/`) over creating new state
