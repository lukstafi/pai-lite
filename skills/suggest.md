# /suggest - Task Suggestions

Provide intelligent task suggestions based on current flow state.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor suggest`
- The user asks "what should I work on?"

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

## Process

1. **Analyze flow state**:
   ```bash
   pai-lite flow ready      # Get ready tasks
   pai-lite flow critical   # Get urgent items
   pai-lite flow context    # Get context distribution
   ```

2. **Consider factors**:
   - **Priority**: A-priority tasks first
   - **Deadlines**: Items with hard deadlines
   - **Impact**: Tasks that unblock the most downstream work
   - **Context**: Minimize context switching if already focused
   - **Effort**: Balance small wins with large projects

3. **Generate suggestions**:
   - Top 3 recommended tasks with reasoning
   - Alternative if primary is blocked
   - Warning about any stalled work

## Output Format

```markdown
## Suggested Tasks

### Top Recommendation
**task-101**: Implement einsum concatenation

*Why*: A-priority, unblocks 3 tasks, matches your current einsum context.

### Alternatives
1. **task-067**: Fix type inference edge case
   - Same context, smaller scope, quick win

2. **task-128**: Update documentation
   - Lower priority but deadline in 5 days

### Consider Later
- task-089 has been stalled for 10 days - need to either restart or abandon
```

## Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "suggestions": [
    {"task": "task-101", "priority": 1, "reason": "..."},
    {"task": "task-067", "priority": 2, "reason": "..."}
  ]
}
```

## Delegation Strategy

- **CLI tools** for flow analysis
- **Opus** for reasoning about suggestions
