# /ludics-techdebt - Technical Debt Review

End-of-day or end-of-week technical debt review.

## Trigger

This skill is invoked when:
- The user runs `ludics mag techdebt`
- Weekly automation (e.g., Friday 17:00)

## Inputs

- `$LUDICS_STATE_PATH`: Path to the harness directory
- `$LUDICS_REQUEST_ID`: Request ID for writing results

## Process

1. **Scan recent commits** (delegate to Haiku for speed):
   ```bash
   # Get commits from last 7 days across watched projects
   for project in $(ludics config projects); do
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
# Technical Debt Review - YYYY-MM-DD

## Summary
- N high-priority items
- N medium-priority items
- N low-priority items

## High Priority

### [project]: [short description]
**Files**: [file paths with line ranges]

**Issue**: [what's wrong]

**Suggestion**: [how to fix]

---

[...more high-priority items...]

## Medium Priority

[TODO comments, moderate duplication, etc.]

## Low Priority

[Style issues, minor items - can reference separate details file]

## Tasks Created
[List any task files created for high-cost items]
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "high": N,
  "medium": N,
  "low": N,
  "tasks_created": [...]
}
```

## Delegation Strategy

- **Haiku** (via Task tool): Scan for duplicated code, TODOs, long functions
- **CLI**: Git log, grep for patterns
- **Opus**: Assess severity, write recommendations

## Notification

If high-priority items found:
```bash
ludics notify pai "Tech debt review: 3 high-priority items found" 3 "Weekly Review"
```
