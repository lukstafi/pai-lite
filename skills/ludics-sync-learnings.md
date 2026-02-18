# /ludics-sync-learnings - Knowledge Consolidation

Consolidate scattered learnings from corrections.md into structured memory files.

## Trigger

This skill is invoked when:
- The user runs `ludics mag sync-learnings`
- Periodically (weekly) via automation
- When corrections.md grows beyond a threshold

## Inputs

- `$LUDICS_STATE_PATH`: Path to the harness directory (environment variable)
- **Request ID**: Read from file `$LUDICS_STATE_PATH/mag/current-request-id` — use as `LUDICS_REQUEST_ID` in result JSON

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

6. **File GitHub issues for harness bugs/improvements**:
   - When corrections reveal a pattern about the ludics harness itself (race conditions,
     missing error handling, architectural issues, missing features), file an issue
   - Ensure the label exists:
     ```bash
     gh label create harness-improvement -R lukstafi/ludics --description "Improvement identified from operational learnings" --color "a2eeef" 2>/dev/null || true
     ```
   - Deduplicate against existing open issues:
     ```bash
     gh issue list -R lukstafi/ludics --label harness-improvement --state open --json number,title,body --limit 100
     ```
   - Create issues for new patterns:
     ```bash
     gh issue create -R lukstafi/ludics --title "<pattern summary>" --label harness-improvement --body "<body>"
     ```
     Issue body format:
     ```markdown
     ## Pattern
     <what was observed across multiple corrections>

     ## Evidence
     - <correction 1 summary> (<date>)
     - <correction 2 summary> (<date>)

     ## Suggested Fix
     <actionable suggestion based on accumulated evidence>

     ---
     *Filed by ludics-sync-learnings from N corrections*
     ```
   - Add comments to existing issues if new corrections add evidence
   - Do not create local task files for these — `ludics tasks sync` will convert
     the GitHub issues to tasks automatically

7. **Stage CLAUDE.md proposals** (if broad patterns detected):
   - Append entries to `$LUDICS_STATE_PATH/AGENTS_STAGING.md`
   - Create the file if it doesn't exist:
     ```markdown
     # Agent Learnings (Staging)

     This file collects agent-discovered learnings for later curation into CLAUDE.md.
     ```
   - Each entry uses HTML comment markers for structure:
     ```markdown
     <!-- Entry: sync-learnings | YYYY-MM-DD -->
     ### <short title>

     <what was learned and proposed CLAUDE.md change>

     **Target**: <which project's CLAUDE.md this applies to>

     <!-- End entry -->
     ```
   - Do not modify CLAUDE.md directly — the human curates from staging

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

## Staged CLAUDE.md Proposals
- N entries appended to AGENTS_STAGING.md
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
  "archived": N,
  "issues_created": N,
  "issues_updated": N
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
