# /pai-suggest - Task Suggestions

Provide intelligent task suggestions based on current flow state.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor suggest`
- The user asks "what should I work on?"

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

## Process

0. **Check inbox**: Run `pai-lite mayor inbox` to see any pending messages.
   Factor any messages into task suggestions and priority reasoning.

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
**task-NNN**: [title]

*Why*: [reasoning based on priority, impact, context, deadlines]

### Alternatives
1. **task-NNN**: [title]
   - [why this is a good alternative]

2. **task-NNN**: [title]
   - [different tradeoff - e.g., smaller scope, approaching deadline]

### Consider Later
- [Any stalled or problematic tasks that need decision]
```

## Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "suggestions": [
    {"task": "task-NNN", "priority": 1, "reason": "..."},
    {"task": "task-NNN", "priority": 2, "reason": "..."}
  ]
}
```

## Delegation Strategy

- **CLI tools** for flow analysis
- **Opus** for reasoning about suggestions
