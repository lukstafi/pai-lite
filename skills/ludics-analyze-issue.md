# /ludics-analyze-issue - GitHub Issue Analysis

Analyze a GitHub issue and create a task file with inferred dependencies.

## Trigger

This skill is invoked when:
- The user runs `ludics mag analyze <issue>`
- Automation detects a new issue in watched repos

## Arguments

- `<issue>`: Issue number (e.g., `127`) or URL (e.g., `https://github.com/org/repo/issues/127`)

## Inputs

- `$LUDICS_STATE_PATH`: Path to the harness directory
- `$LUDICS_REQUEST_ID`: Request ID for writing results

## Process

1. **Fetch issue**:
   ```bash
   gh issue view <issue> --json title,body,labels,assignees,milestone
   ```

2. **Assess actionability**:
   - Is this a feature request, bug report, or discussion?
   - Is it clear enough to act on?
   - Does it need clarification?

3. **Extract dependencies** (delegate to Haiku for speed):
   ```
   Task → Haiku: "Extract dependencies from this issue.
   Return JSON: {blocks: [...], blocked_by: [...], related: [...]}"
   ```

4. **Validate dependencies**:
   - Check that referenced tasks exist
   - Run `tsort` to verify no cycles are introduced
   ```bash
   echo "existing deps + new deps" | tsort
   ```

5. **Infer metadata**:
   - Priority (A/B/C) based on labels, milestone, urgency
   - Effort (small/medium/large) based on scope
   - Context tag based on repository/area

6. **Create task file**:
   Write `$LUDICS_STATE_PATH/tasks/task-<next_id>.md`

## Output Format

### Task File

```yaml
---
id: task-NNN
title: "[concise title from issue]"
project: [project name]
status: ready
priority: [A/B/C based on labels, milestone, urgency]
deadline: [if any]
dependencies:
  blocks: []
  blocked_by: [...]
effort: [small/medium/large]
context: [area tag]
slot: null
adapter: null
created: YYYY-MM-DD
started: null
completed: null
github_issue: [issue number]
---

## Context

From GitHub issue #NNN:
[Summary of the issue in your own words]

## Acceptance Criteria

- [ ] [criteria derived from issue]
- [ ] [...]

## Technical Notes

[Code pointers, relevant files, implementation hints - if identifiable]

## Dependencies

[Explain blocking relationships if any]
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "output": "Created task-NNN.md from issue #NNN",
  "task_id": "task-NNN",
  "github_issue": NNN
}
```

## Delegation Strategy

- **Haiku** (via Task tool): Extract structured data (dependencies, effort estimate)
- **CLI**: Validate dependencies with tsort
- **Opus**: Write the task file with context and acceptance criteria

## Error Handling

- Issue not found: Write result with status "error"
- Cycle detected: Warn but still create task, note dependency issue
- Ambiguous issue: Create task with status "blocked" and note clarification needed
