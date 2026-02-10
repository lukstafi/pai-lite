# /pai-briefing - Strategic Morning Briefing

Generate a comprehensive strategic briefing for the user.

## Trigger

This skill is invoked by the pai-lite automation when:
- The user runs `pai-lite briefing` or `pai-lite mayor briefing`
- A morning trigger fires (e.g., 08:00 via launchd)

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results
- `$PAI_LITE_RESULTS_DIR`: Directory for writing result JSON

## Process

0. **Check inbox**: Run `pai-lite mayor inbox` to see any pending messages.
   If there are messages, treat them as high-priority context that should influence
   the briefing content, suggestions, and priority assessments below.

1. **Check for same-day briefing**:
   - Read the existing `$PAI_LITE_STATE_PATH/briefing.md` and extract the date from its `# Briefing - YYYY-MM-DD` title
   - If today's date matches the existing briefing date, **amend** rather than regenerate:
     - Skim current state for anything that changed (slot activity, task status, new tasks)
     - Apply light-touch updates to the affected sections only
     - Do not re-elaborate tasks or redo the full analysis
     - Skip to step 6 (Write result) after amending
   - If the dates differ or no briefing exists, proceed with the full process below

2. **Gather context**:
   - Read `slots.md` to understand active work
   - Read `tasks/*.md` to understand task inventory
   - Read `sessions.json` (if present) to spot unassigned sessions
   - Use flow engine to compute ready queue: `pai-lite flow ready`
   - Check for critical items: `pai-lite flow critical`
   - Read recent journal entries: `journal/*.md`

3. **Elaborate unprocessed tasks** (before analysis):
   - Run `pai-lite tasks needs-elaboration` to find unprocessed tasks
   - For tasks that might appear in the briefing (ready, high-priority, or deadline soon):
     - Use the Task tool to invoke `/pai-elaborate <task-id>` inline
     - This ensures the briefing has detailed task information
   - Example (parallel elaboration of candidates):
     ```
     Task tool: /pai-elaborate task-101
     Task tool: /pai-elaborate task-042
     ```

4. **Analyze state**:
   - Identify high-priority ready tasks (A-priority, empty blocked_by)
   - Detect approaching deadlines (within 7 days)
   - Identify stalled work (in-progress > 7 days without updates)
   - Check slot utilization (X/6 slots active)

5. **Generate briefing**:
   Write a strategic briefing covering:
   - **Current state**: Active slots, ongoing work
   - **Unassigned sessions**: Any active sessions not mapped to slots (from `sessions.json`)
   - **Ready tasks**: Priority-sorted list of what can start
   - **Urgent items**: Deadlines, stalled work, blockers
   - **Suggestions**: What to work on today and why
   - **Context switches**: Note if changing context is expensive

6. **Write result**:
   - Write briefing to `$PAI_LITE_STATE_PATH/briefing.md`
   - Write result JSON to `$PAI_LITE_RESULTS_DIR/$PAI_LITE_REQUEST_ID.json`

7. **Commit and push state**:
   - Run `pai-lite sync` to commit the briefing to the state repo and push to remote
   - This archives the briefing via git history and propagates it to the remote

## Output Format

### briefing.md

```markdown
# Briefing - YYYY-MM-DD

## Current State
- Slot 1: [task] (agent-duo, phase)
- Slot 2: empty
- ...

## Ready to Start (Priority Order)
1. **task-101** (A): [title] - [reason this is high priority]
2. **task-067** (A): [title]
3. **task-128** (B): [title]

## Urgent Attention
- **Deadline**: task-042 due in 3 days (POPL submission)
- **Stalled**: task-089 has been in-progress for 12 days

## Today's Suggestion
Start with task-101 because [reasoning]. If blocked, switch to task-067.

Current context focus: [einsum/ocannl] - switching to [other] would incur context cost.

## Notes
- [Any other strategic observations]
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "2026-02-01T08:00:00Z",
  "output": "[briefing content]"
}
```

## Delegation Strategy

- **CLI tools** for ready queue computation (yq, jq, tsort)
- **Task tool** to invoke `/pai-elaborate` for unprocessed tasks (parallel)
- **Direct Opus analysis** for strategic suggestions

## Error Handling

If state files are missing or malformed:
- Write partial briefing with warnings
- Include "run pai-lite tasks sync" suggestion
- Still write result JSON with status "partial"
