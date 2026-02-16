# /ludics-preempt - Priority Project Preemption

Decide which slot to preempt for a priority project task.

## Trigger

This skill is invoked when:
- A priority project task is detected during `ludics tasks sync`
- All slots are occupied and a priority task needs immediate attention

## Arguments

- `$1` — Task ID (e.g., `gh-myrepo-42`)
- `$2` — Autonomy level: `auto` or `suggest`

## Process

1. **Read task details**:
   ```bash
   ludics tasks show $1
   ```

2. **Read all slot states**:
   ```bash
   ludics slots
   ```

3. **Check for existing preemptions**:
   Look in `harness/mag/preempted/` for any existing stash files.
   Never preempt a slot that already has a stash (no double preemption).

4. **Evaluate each slot** using these criteria:
   - **Never preempt another priority project task** — check if the slot's current task belongs to a priority project
   - **Prefer lower-priority tasks** — tasks with priority C over B over A
   - **Prefer tasks with less time invested** — recently started tasks are cheaper to pause
   - **Consider context** — prefer preempting tasks in unrelated contexts
   - **Prefer manual/idle adapters** — less disruption

5. **Select the best slot** to preempt based on the above criteria.

6. **Act based on autonomy level**:

   ### `auto` mode
   Execute the preemption directly:
   ```bash
   ludics slot N preempt $TASK_ID -a claude-code
   ```

   ### `suggest` mode
   Send a notification with the recommendation:
   ```bash
   ludics notify outgoing "Priority task $TASK_ID ready. Recommend preempting slot N (currently: <description>). Run: ludics slot N preempt $TASK_ID"
   ```

## Output Format

```markdown
## Preemption Decision

**Task**: $TASK_ID — [title]
**Selected Slot**: N
**Reason**: [why this slot was chosen]
**Action**: [executed / suggested]

### Slot Analysis
| Slot | Task | Priority | Age | Preemptable | Score |
|------|------|----------|-----|-------------|-------|
| 1    | ...  | B        | 2d  | yes         | 0.8   |
| 2    | ...  | A        | 5d  | no (priority)| -    |
| ...  | ...  | ...      | ... | ...         | ...   |
```

## Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "action": "preempt",
  "task": "...",
  "selectedSlot": N,
  "autonomy": "auto|suggest",
  "executed": true
}
```

## Delegation Strategy

- **CLI tools** for slot/task state
- **Opus** for reasoning about which slot to preempt
