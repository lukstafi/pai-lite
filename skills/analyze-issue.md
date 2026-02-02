# /analyze-issue - GitHub Issue Analysis

Analyze a GitHub issue and create a task file with inferred dependencies.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor analyze <issue>`
- Automation detects a new issue in watched repos

## Arguments

- `<issue>`: Issue number (e.g., `127`) or URL (e.g., `https://github.com/org/repo/issues/127`)

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

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
   Write `$PAI_LITE_STATE_PATH/tasks/task-<next_id>.md`

## Output Format

### Task File

```yaml
---
id: task-143
title: "Implement tensor concatenation with ^ operator"
project: ocannl
status: ready
priority: B
deadline: null
dependencies:
  blocks: []
  blocked_by: [task-042]
effort: medium
context: einsum
slot: null
adapter: null
created: 2026-02-01
started: null
completed: null
github_issue: 127
---

# Context

From GitHub issue #127:
[Summary of the issue in your own words]

# Acceptance Criteria

- [ ] Parse `^` in einsum expressions
- [ ] Implement projection inference for concatenation
- [ ] Add tests for edge cases
- [ ] Update documentation

# Technical Notes

[Any code pointers, relevant files, or implementation hints]

# Dependencies

- Blocked by task-042 (einsum parser refactoring)
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "output": "Created task-143.md from issue #127",
  "task_id": "task-143",
  "github_issue": 127
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
