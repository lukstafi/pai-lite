# /ludics-sync-learnings - Knowledge Consolidation

Consolidate scattered learnings from corrections.md into structured memory files.

## Trigger

This skill is invoked when:
- The user runs `ludics mag sync-learnings`
- Periodically (weekly) via automation
- When corrections.md grows beyond a threshold

## Inputs

- `$LUDICS_STATE_PATH`: Path to the harness directory
- `$LUDICS_REQUEST_ID`: Request ID for writing results

## Process

1. **Read recent corrections**:
   ```bash
   cat "$LUDICS_STATE_PATH/mag/memory/corrections.md"
   ```

2. **Read journal friction points**:
   ```bash
   grep -l "friction\|mistake\|learned" "$LUDICS_STATE_PATH/journal/"*.md
   ```

3. **Group by theme**:
   - Tool-related → tools.md
   - Process-related → workflows.md
   - Project-specific → projects/<project>.md

4. **Update structured files**:
   - Merge similar learnings
   - Remove duplicates
   - Add cross-references

5. **Archive processed corrections**:
   - Move entries to `corrections-archive.md`
   - Keep corrections.md for recent items only

6. **Propose CLAUDE.md updates** (if broad patterns detected):
   - Output suggestions for codebase-wide instructions
   - Do not auto-update CLAUDE.md

## Output Format

### Sync Report

```markdown
# Learnings Sync - YYYY-MM-DD

## Processed
- N corrections from corrections.md
- N friction points from journal

## Updates Made

### tools.md
- [what was added/updated]

### workflows.md
- [what was added/updated]

### projects/[project].md
- [what was added/updated]

## Archived
- Moved N processed corrections to corrections-archive.md

## Suggested CLAUDE.md Updates
[If broad patterns detected, suggest additions - do not auto-update]
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "processed": N,
  "updates": {
    "tools.md": N,
    "workflows.md": N,
    "projects/[project].md": N
  },
  "archived": N
}
```

## Memory File Structure

The structured memory files follow these patterns:

- **tools.md**: CLI tool knowledge organized by tool, with Usage and Gotchas subsections
- **workflows.md**: Process patterns as numbered steps or checklists
- **projects/[project].md**: Project-specific knowledge (build system, key modules, common issues)

## Delegation Strategy

- **Haiku** (via Task tool): Extract themes and group corrections
- **Opus**: Write the consolidated memory files with judgment
