# /ludics-health-check - System Health Check

Detect approaching deadlines and other issues requiring attention.

## Trigger

This skill is invoked when:
- The user runs `ludics mag health-check`
- Periodic automation (every 4h via launchd)

## Inputs

- `$LUDICS_STATE_PATH`: Path to the harness directory (environment variable)
- **Request ID**: Read from file `$LUDICS_STATE_PATH/mag/current-request-id` — use as `LUDICS_REQUEST_ID` in result JSON

## Process

1. **Check approaching deadlines**:
   - Find tasks with `deadline` field
   - Calculate days remaining
   - Flag if <= 7 days (warning) or <= 3 days (critical)

2. **Check slot health**:
   - Read `slots.md`
   - Identify slots that have been active > 24h without status update
   - Run `ludics sessions report` and check for orphaned/unclassified sessions
     (sessions with no slot match in `sessions.md`)

3. **Check queue health**:
   - Read `mag/queue.jsonl`
   - Flag if requests have been pending > 1h

4. **Report task elaboration status**:
   - Run `ludics tasks needs-elaboration` to count unprocessed tasks
   - Note: Elaboration queueing is handled automatically by `tasks_queue_elaborations()` in `tasks_sync()` -- no need to enqueue here

5. **Generate report**:
   - Categorize issues by severity
   - Include actionable recommendations

6. **Send notifications** for critical issues:
   ```bash
   ludics notify outgoing "Critical: task-042 deadline in 2 days" 5 "Health Check"
   ```

## Output Format

### Health Report

```markdown
# Health Check - YYYY-MM-DD HH:MM

## Critical Issues
- **DEADLINE**: task-042 "POPL submission" due in 2 days

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
- 2 tasks awaiting elaboration (queued automatically by mag keepalive)

## Recommendations
1. Prioritize task-042 - deadline is imminent
2. Slot 3 may need attention - check tmux session
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
| Deadline <= 3 days | outgoing | 5 (critical) |
| Deadline <= 7 days | outgoing | 4 (high) |
| Queue stuck > 1h | agents | 4 (high) |

## Delegation Strategy

- **CLI tools**: Date calculations, file parsing
- **Opus**: Judgment on severity, recommendations
