# Agent Learnings (Staging)

This file contains learnings discovered by AI agents during development sessions.
Periodically review and consolidate valuable entries into `CLAUDE.md` or `AGENTS.md`.

---


<!-- Entry: pervasive_session_discovery-claude | 2026-02-10 -->
### Bash brace default expansion bug

In bash, ${var:-{}} is ambiguous — when $var has a value containing braces, the expansion appends an extra }. Use [[ -n "$var" ]] || var="{}" instead.
<!-- End entry -->

<!-- Entry: pervasive_session_discovery-claude | 2026-02-10 -->
### Pipe-while subshell trap

In bash, cmd | while read ...; do ... done runs the while body in a subshell. Variable modifications (like accumulating into _SESSIONS_RAW) are lost. Fix: capture output to a variable first, then use while ... done <<< "$var".
<!-- End entry -->

<!-- Entry: pervasive_session_discovery-claude | 2026-02-10 -->
### Claude Code session stores

Claude Code stores session metadata in two places:
- `~/.claude/projects/<encoded-path>/sessions-index.json` — rich metadata (sessionId, fileMtime in ms, projectPath, gitBranch, summary, messageCount, isSidechain). Preferred source.
- `~/.claude/projects/<encoded-path>/<session-id>.jsonl` — fallback. Root entry has `"parentUuid": null` with `cwd` and `sessionId`.

Codex stores sessions in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (date-organized layout, NOT flat). First line is `{"type":"session_meta","payload":{...}}`.
<!-- End entry -->

<!-- Entry: pervasive_session_discovery-claude | 2026-02-10 -->
### Slot Path field for session classification

Adding an explicit `**Path:**` field to the slot block format makes slot-to-directory mapping first-class. This is cleaner than inferring paths from Git "Working directory:" lines or Session field guessing. Use with `slot assign --path /abs/path`.
<!-- End entry -->
