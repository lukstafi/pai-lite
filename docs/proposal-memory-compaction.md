# Proposal: Compaction and Memory Management

## Current State

Mag's persistent memory lives in flat files:

| File | Purpose | Growth pattern |
|------|---------|----------------|
| `mag/context.md` | Current understanding, preferences | Manual edits by Mag |
| `mag/memory/user-preferences.md` | Long-term user preferences | Appended by `/ludics-learn` |
| `mag/past-messages.md` | Archived inbox messages | Grows unboundedly |
| `journal/YYYY-MM-DD.md` | Daily activity logs | One file per day |
| `journal/notifications.jsonl` | Notification history | Grows unboundedly |
| `briefing.md` | Latest briefing | Overwritten daily |
| Task files (`tasks/*.md`) | Task specs with frontmatter | Grows with project scope |

**What Mag loads per skill invocation**: CLAUDE.md instructions, the skill file, and whatever files the skill tells it to read (context.md, task files, briefing-context.md, etc.). There is no automatic relevance filtering — Mag reads everything the skill lists.

## Problems

1. **Context.md becomes stale**: Observations from weeks ago sit alongside current state. Mag has no mechanism to prune outdated context.
2. **No retrieval by relevance**: When elaborating task-042, Mag has no way to find "we discussed a similar tensor operation in task-019's elaboration" without reading all task files.
3. **Journal grows unboundedly**: After months of operation, `journal/` contains hundreds of files. The briefing reads the last 20 entries but has no way to surface patterns.
4. **Past messages accumulate**: `past-messages.md` is append-only with no summarization.
5. **Learnings are unstructured**: `/ludics-learn` appends to `memory/user-preferences.md` — a flat file that becomes a grab-bag.

## Proposal: Structured Memory with Periodic Compaction

### Tiered memory model

```
mag/memory/
├── active.md          # Current priorities, active decisions (small, frequently updated)
├── patterns.md        # Recurring observations (compacted from journals)
├── corrections.md     # User corrections and preferences (from /ludics-learn)
├── project/
│   ├── ocannl.md      # Per-project institutional knowledge
│   └── ppx-minidebug.md
└── archive/
    ├── 2026-W07.md    # Weekly compaction of journal + messages
    └── 2026-W06.md
```

### Compaction process (new skill: `/ludics-compact`)

Run weekly (or when `active.md` exceeds a threshold, say 200 lines):

1. **Journal compaction**: Read all journal entries for the past week. Extract:
   - Recurring patterns ("task-X blocked three times by Y")
   - Completed decisions (move from `active.md` to archive)
   - Project-specific insights (append to `project/<name>.md`)
   Write weekly summary to `archive/YYYY-WNN.md`.

2. **Context rotation**: Review `active.md`:
   - Remove entries about completed/abandoned tasks
   - Move stable observations to `patterns.md`
   - Keep only items relevant to current slots and ready queue

3. **Message compaction**: Summarize `past-messages.md` into the weekly archive, then truncate.

4. **Notification compaction**: Summarize `notifications.jsonl` entries older than 30 days, write summary to archive, truncate the JSONL.

### Trigger

Add to the existing trigger system:

```yaml
triggers:
  compact:
    enabled: true
    day: sunday     # Weekly
    hour: 3
    minute: 0
    action: mag compact
```

Or let Mag self-schedule via dynamic cron (see proposal-cron-webhooks.md).

### Retrieval: grep over structured files

Agents (Mag and slot workers) can search memory using standard tools — no indexing infrastructure needed:

```bash
# Mag searching for past decisions about tensor operations
grep -rl "tensor\|einsum" mag/memory/project/ mag/memory/archive/

# Or using a standalone search tool if we add one as a dependency
```

The tiered structure makes grep effective: `project/ocannl.md` is small and topical, `patterns.md` captures cross-project recurring themes, and weekly archives are date-scoped. An agent looking for context on task-042 reads `project/ocannl.md` (~1 file) rather than scanning all journals (~hundreds of files).

### Briefing context enhancement

Improve the briefing context generator to include project-specific memory for active slots:

```typescript
// In briefingPrecomputeContext(), after existing sections:
for (const slot of activeSlots) {
  const projectMemory = join(harness, "mag", "memory", "project", `${slot.project}.md`);
  if (existsSync(projectMemory)) {
    context += `\n## Project Memory: ${slot.project}\n\n${readFileSync(projectMemory, "utf-8")}`;
  }
}
```

This gives Mag relevant institutional knowledge without loading everything.

### Cost

- 1 new skill file (`ludics-compact.md`, ~40 lines)
- 1 new queue action mapping in `mag.ts`
- 1 new trigger definition (or dynamic cron entry)
- ~15 lines in `briefingPrecomputeContext()` for project memory inclusion
- Mag does the actual compaction work (strategic summarization — exactly what an LLM is good at)

### Why not a vector database

A vector-indexed memory (SQLite + embeddings) would add an embedding model dependency, a database with schema management, and an indexing pipeline. This is infrastructure that belongs in the agentic layer (Claude Code, Codex, etc.) — not in the coordination harness. As agent runtimes gain better memory and retrieval capabilities natively, custom infrastructure here would become dead weight. The structured file layout + grep provides sufficient retrieval for the scale we operate at, and stays out of the way when agents improve.

## Summary

Compaction is a **strategic** task (deciding what's important, what's stale, what patterns emerge) — exactly what Mag is designed for. The solution matches the philosophy: Mag does the judgment work, deterministic file structure makes the results greppable. No new dependencies.
