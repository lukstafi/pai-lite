# /pai-health-check - System Health Check

Detect stalled work, approaching deadlines, and other issues requiring attention.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor health-check`
- Periodic automation (every 4h via launchd)

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

## Process

0. **Check inbox**: Run `pai-lite mayor inbox` to see any pending messages.
   Factor any messages into the health check assessment.

1. **Check for stalled tasks**:
   - Find tasks with `status: in-progress`
   - Calculate time since `started` date
   - Flag if > 7 days without updates

2. **Check approaching deadlines**:
   - Find tasks with `deadline` field
   - Calculate days remaining
   - Flag if <= 7 days (warning) or <= 3 days (critical)

3. **Check slot health**:
   - Read `slots.md`
   - Identify slots that have been active > 24h without status update
   - Check for orphaned sessions (tmux sessions without slot assignment)

4. **Check queue health**:
   - Read `mayor/queue.jsonl`
   - Flag if requests have been pending > 1h

5. **Report task elaboration status**:
   - Run `pai-lite tasks needs-elaboration` to count unprocessed tasks
   - Note: Elaboration queueing is handled automatically by `tasks_queue_elaborations()` in `tasks_sync()` — no need to enqueue here

6. **Generate report**:
   - Categorize issues by severity
   - Include actionable recommendations

7. **Send notifications** for critical issues:
   ```bash
   pai-lite notify pai "Critical: task-042 deadline in 2 days" 5 "Health Check"
   ```

## Output Format

### Health Report

```markdown
# Health Check - YYYY-MM-DD HH:MM

## Critical Issues
- **DEADLINE**: task-042 "POPL submission" due in 2 days
- **STALLED**: task-089 in-progress for 14 days

## Warnings
- **DEADLINE**: task-101 due in 6 days
- **SLOT**: Slot 3 has been active for 28 hours without update

## Info
- Active slots: 2/6
- Ready tasks: 8
- Blocked tasks: 3
- Queue pending: 0
- Tasks needing elaboration: 5

## Elaboration Status
- 2 tasks awaiting elaboration (queued automatically by mayor keepalive)

## Recommendations
1. Prioritize task-042 - deadline is imminent
2. Review task-089 - consider abandoning or breaking into smaller pieces
3. Slot 3 may need attention - check tmux session
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "critical": 2,
  "warnings": 2,
  "output": "[health report content]"
}
```

## Notification Triggers

| Condition | Topic | Priority |
|-----------|-------|----------|
| Deadline <= 3 days | pai | 5 (critical) |
| Deadline <= 7 days | pai | 4 (high) |
| Stalled > 14 days | pai | 4 (high) |
| Stalled > 7 days | pai | 3 (normal) |
| Queue stuck > 1h | agents | 4 (high) |

## Delegation Strategy

- **CLI tools**: Date calculations, file parsing
- **Opus**: Judgment on severity, recommendations
