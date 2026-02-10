# Agent Learnings (Staging)

This file contains learnings discovered by AI agents during development sessions.
Periodically review and consolidate valuable entries into `CLAUDE.md` or `AGENTS.md`.

---


<!-- Entry: pervasive_session_discovery-codex | 2026-02-09 -->
### Claude sessions-index.json

Peer implementation highlights Claude Code stores session metadata in sessions-index.json under ~/.claude/projects/<project>/, which may be a faster/cleaner source than scanning JSONL.
<!-- End entry -->
<!-- Entry: pervasive_session_discovery-codex | 2026-02-10 -->
### Codex sessions directory layout

Codex session JSONL files live under nested date folders: `~/.codex/sessions/YYYY/MM/DD/*.jsonl`. A top-level `sessions/` listing only shows year directories, so discovery should walk recursively.

<!-- End entry -->
