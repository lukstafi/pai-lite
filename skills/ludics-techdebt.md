# /ludics-techdebt - Technical Debt Review

End-of-day or end-of-week technical debt review.

## Trigger

This skill is invoked when:
- The user runs `ludics mag techdebt`
- Weekly automation (e.g., Friday 17:00)

## Inputs

- `$LUDICS_STATE_PATH`: Path to the harness directory (environment variable)
- **Request ID**: Read from file `$LUDICS_STATE_PATH/mag/current-request-id` — use as `LUDICS_REQUEST_ID` in result JSON

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
   - Dead code (unreachable paths, unused functions)
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

5. **Decide per item: GitHub issue, comment on existing issue, or local task**:

   - **File a new GitHub issue** when the item is a new concern that deserves its own
     visibility — bugs, architectural problems, missing features, significant duplication
     patterns, design decisions worth discussing. Issues filed to watched repos will be
     pulled back as tasks automatically by `ludics tasks sync`.
   - **Comment on an existing issue** when the item is a refinement of work already tracked —
     fits into a pre-existing issue, belongs to an already-tracked development path, or is
     an incremental improvement on work-in-progress. Add the finding as a comment rather
     than creating noise with a new issue. If the item is independently actionable, also
     create a local task file with `subtask_of: <issue-task-id>` (if it's a piece of that
     issue's work) or `relates_to: <issue-task-id>` (if it's adjacent).
   - **Create a local task file** (C-priority) only for items that don't belong in any issue
     tracker — quick cleanups that can just be done when a slot is free.

   For GitHub issues:
   - Use the project's repo from the config
   - Ensure the label exists:
     ```bash
     gh label create techdebt -R <repo> --description "Technical debt identified by Mag" --color "e4e669" 2>/dev/null || true
     ```
   - Fetch existing open issues to deduplicate:
     ```bash
     gh issue list -R <repo> --label techdebt --state open --json number,title,body --limit 100
     ```
   - For each item, compare against existing issues:
     - **New**: No existing issue covers this → create issue
     - **Overlaps**: Existing issue covers related ground → add comment with new data
     - **Duplicate**: Already captured → skip
   - Create issues:
     ```bash
     gh issue create -R <repo> --title "<short description>" --label techdebt --body "<body>"
     ```
     Issue body format:
     ```markdown
     ## Description
     <what's wrong and where>

     ## Files
     <file paths with line ranges>

     ## Suggestion
     <how to fix>

     ## Severity
     <High/Medium with rationale>

     ---
     *Filed by ludics-techdebt*
     ```

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
  "tasks_created": [...],
  "issues_created": N,
  "issues_updated": N,
  "issues_skipped": N
}
```

## Delegation Strategy

- **Haiku** (via Task tool): Scan for duplicated code, TODOs, long functions
- **CLI**: Git log, grep for patterns
- **Opus**: Assess severity, write recommendations

## Notification

If high-priority items found:
```bash
ludics notify outgoing "Tech debt review: 3 high-priority items found" 3 "Weekly Review"
```

If issues were filed:
```bash
ludics notify outgoing "Filed N techdebt issues (M repos)" 3 "Tech Debt"
```
