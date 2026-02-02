# /sync-learnings - Knowledge Consolidation

Consolidate scattered learnings from corrections.md into structured memory files.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor sync-learnings`
- Periodically (weekly) via automation
- When corrections.md grows beyond a threshold

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

## Process

1. **Read recent corrections**:
   ```bash
   cat "$PAI_LITE_STATE_PATH/mayor/memory/corrections.md"
   ```

2. **Read journal friction points**:
   ```bash
   grep -l "friction\|mistake\|learned" "$PAI_LITE_STATE_PATH/journal/"*.md
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
# Learnings Sync - 2026-02-01

## Processed
- 12 corrections from corrections.md
- 3 friction points from journal

## Updates Made

### tools.md
- Added yq gotchas section
- Added jq multiline handling note

### workflows.md
- Added "PR review checklist" pattern
- Updated "task elaboration" process

### projects/ocannl.md
- Added einsum parsing notes
- Added build system quirks

## Archived
- Moved 8 processed corrections to corrections-archive.md

## Suggested CLAUDE.md Updates
Consider adding:
> When using yq, prefer `yq eval` over `yq -s` for single file operations.
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "processed": 12,
  "updates": {
    "tools.md": 2,
    "workflows.md": 2,
    "projects/ocannl.md": 2
  },
  "archived": 8
}
```

## Memory File Formats

### tools.md

```markdown
# CLI Tools Knowledge

## yq

### Usage
- Single file: `yq eval '.key' file.yaml`
- Multiple files: `yq -s '.' *.yaml`

### Gotchas
- `yq -s` expects multiple files
- Output is JSON by default, use `-o yaml` for YAML

## jq

### Gotchas
- Use `--slurpfile` for loading JSON files as variables
- Multiline strings need careful quoting
```

### workflows.md

```markdown
# Workflow Patterns

## Task Elaboration
1. Read task file and linked issue
2. Check related tasks for context
3. Identify specific files to modify
4. Break into subtasks with acceptance criteria

## PR Review Checklist
- [ ] Tests pass
- [ ] No new warnings
- [ ] Documentation updated if needed
- [ ] Commit message follows convention
```

### projects/ocannl.md

```markdown
# OCANNL Project Knowledge

## Build System
- Uses dune
- `dune build` from root
- Tests: `dune test`

## Einsum Module
- Parser at `lib/einsum/parser.ml`
- Entry point: `parse_einsum`
- Uses menhir for parsing

## Common Issues
- Type inference can be slow on large tensors
- Watch for dimension broadcasting edge cases
```

## Delegation Strategy

- **Haiku** (via Task tool): Extract themes and group corrections
- **Opus**: Write the consolidated memory files with judgment
