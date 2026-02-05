# /pai-techdebt - Technical Debt Review

End-of-day or end-of-week technical debt review.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor techdebt`
- Weekly automation (e.g., Friday 17:00)

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

## Process

1. **Scan recent commits** (delegate to Haiku for speed):
   ```bash
   # Get commits from last 7 days across watched projects
   for project in $(pai-lite config projects); do
     git -C "$project" log --since="7 days ago" --oneline
   done
   ```

2. **Identify code smells**:
   - TODO/FIXME comments added recently
   - Duplicated code blocks (>80% similarity)
   - Unused imports or dead code
   - Copy-pasted patterns that could be consolidated
   - Long functions (>100 lines) added

3. **Categorize by maintenance cost**:
   - **Low**: Style issues, minor duplication
   - **Medium**: TODO comments, moderate duplication
   - **High**: Significant duplication, architectural issues

4. **Generate report**:
   - Group by project
   - Include file locations
   - Suggest consolidation approaches

5. **Optionally create task files**:
   - For high-cost items, create C-priority tasks
   - Include in next week's ready queue

## Output Format

### Tech Debt Report

```markdown
# Technical Debt Review - 2026-02-01

## Summary
- 3 high-priority items
- 7 medium-priority items
- 12 low-priority items

## High Priority

### ocannl: Duplicated einsum parsing
**Files**:
- `lib/einsum/parser.ml:142-180`
- `lib/einsum/legacy_parser.ml:89-127`

**Issue**: 80% code similarity in parsing logic

**Suggestion**: Extract common parsing functions to shared module

**Estimated effort**: Medium

---

### ppx-minidebug: Long function
**File**: `lib/ppx_minidebug.ml:423-580` (157 lines)

**Issue**: `transform_expr` is too long, hard to maintain

**Suggestion**: Break into helper functions by expression type

---

## Medium Priority

### ocannl: TODO comment
**File**: `lib/tensor.ml:89`
**Comment**: `(* TODO: optimize for sparse tensors *)`
**Added**: 2026-01-28

---

### ppx-minidebug: Unused import
**File**: `lib/ppx_minidebug.ml:3`
**Import**: `open Unused_module`

---

## Low Priority
- Minor style inconsistencies (12 items)
- See full list in `techdebt-details.md`

## Tasks Created
- task-201: Consolidate einsum parsing (C-priority)
- task-202: Refactor transform_expr (C-priority)
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "high": 3,
  "medium": 7,
  "low": 12,
  "tasks_created": ["task-201", "task-202"]
}
```

## Delegation Strategy

- **Haiku** (via Task tool): Scan for duplicated code, TODOs, long functions
- **CLI**: Git log, grep for patterns
- **Opus**: Assess severity, write recommendations

## Notification

If high-priority items found:
```bash
pai-lite notify pai "Tech debt review: 3 high-priority items found" 3 "Weekly Review"
```
