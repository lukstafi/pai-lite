# pai-lite

A lightweight personal AI infrastructure — a harness for humans working with AI agents.

## What is this?

pai-lite helps you manage multiple concurrent AI agent sessions while keeping yourself (the human) in the loop. Inspired by [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) but much simpler — no complex memory systems, just practical orchestration.

## Core Concepts

### Slots (not tasks, not memory — CPUs)

You have ~6 slots of working attention. Each slot is like a CPU:
- Can run one process at a time
- Holds runtime state while active (context, open questions, "where was I")
- Has no persistent identity — slot 3 isn't "the OCANNL slot," it just happens to be running OCANNL now
- Context switching has a cost

### Task Aggregation

Pull tasks from multiple sources into one view:
- GitHub issues across your repos
- TODOs from READMEs
- Roadmap items from CHANGES.md or similar
- Personal chores (via a private repo's issues)

### Adapters

pai-lite doesn't run agents itself — it coordinates whatever you're using:
- [agent-duo](https://github.com/lukstafi/agent-duo) — two agents working in parallel
- Plain Claude Code sessions
- Vibe Kanban, Gastown, or other orchestrators
- Even a browser tab with claude.ai

### Triggers

React to events:
- Laptop startup → morning briefing
- Repo changes → update task index
- Time-based → daily review

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — detailed design and concepts

## Related Projects

- [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) — the full-featured inspiration
- [agent-duo](https://github.com/lukstafi/agent-duo) — coordinate two agents on one task
- [Vibe Kanban](https://github.com/BloopAI/vibe-kanban) — kanban board for AI agents
- [Gastown](https://github.com/steveyegge/gastown) — multi-agent workspace manager

## Status

🚧 **Early development** — architecture defined, implementation in progress.

## License

MIT
