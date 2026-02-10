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

## Pre-computed Context

All data gathering (slots refresh, session discovery, flow computations, inbox,
journal, same-day check) has been done by bash before this skill runs.

Read the context file:
```
cat $PAI_LITE_STATE_PATH/mayor/briefing-context.md
```

If the file is missing, run `pai-lite mayor context` to generate it.
If that also fails, escalate to the user.

The context file contains these sections:
- **Same-Day Status**: `new` (full briefing) or `amend` (light-touch update)
- **Inbox Messages**: Pre-consumed messages (treat as high-priority context)
- **Slots State**: Current slot assignments after adapter refresh
- **Sessions Report**: All discovered agent sessions with classification
- **Flow: Ready Queue**: Priority-sorted ready tasks
- **Flow: Critical Items**: Deadlines, stalled work, high-priority ready
- **Tasks Needing Elaboration**: Task IDs that lack elaboration
- **Recent Journal**: Last 20 journal entries

Also read `$PAI_LITE_STATE_PATH/tasks/*.md` for full task details.

## Process

1. **Read context**: Read `$PAI_LITE_STATE_PATH/mayor/briefing-context.md`

2. **Check same-day status**: Look at the `## Same-Day Status` section.
   - If `Status: amend`: do a light-touch update only:
     - Skim the context for changes since the last briefing
     - Update affected sections of `$PAI_LITE_STATE_PATH/briefing.md` only
     - Run a lightweight slot reassignment (only newly-empty slots
       or newly-ready high-priority tasks)
     - Do not re-elaborate tasks or redo the full analysis
     - Skip to step 6 (Write result)
   - If `Status: new`: proceed with the full process below

3. **Elaborate unprocessed tasks**:
   - Check the `## Tasks Needing Elaboration` section
   - For tasks that appear in the ready queue or are high-priority:
     - Use the Task tool to invoke `/pai-elaborate <task-id>` (parallel)

4. **Analyze and split work**:
   - Identify high-priority ready tasks, approaching deadlines (7 days),
     stalled work (in-progress > 7 days), slot utilization
   - Factor in inbox messages as high-priority context
   - Check whether tasks or projects should be split into finer-grained units:
     - Multiple git worktrees under the same repo → separate sub-projects
       (exception: worktrees from the same agent-duo feature are one unit)
     - Large tasks with independent acceptance criteria → sub-tasks
   - Mechanical outcomes:
     - Sub-projects: `pai-lite slot N assign "<project>" -a <adapter> -p <path>`
     - Sub-tasks: `pai-lite tasks create "<title>" <project> <priority>` or
       `/pai-elaborate <task-id>` to break into children

5. **(Re)Assign slots**:

   Slot states: **Empty** (available), **Project-reserved** (path+mode, no task),
   **Task-assigned** (active work).

   **Identify opportunities:**
   - Empty slots (candidates for filling)
   - Stalled/completed slots (candidates for clearing)
   - Cross-reference with ready queue and unclassified sessions

   **Build assignment plan:**
   - For empty slots: pick highest-priority ready task, prefer context affinity
   - If an unclassified session is running on a project path, reserve the slot
   - When all slots occupied: weigh eviction cost vs. new task priority
   - Commands:
     - Project reservation: `pai-lite slot N assign "<project> development" -a <adapter> -p <path>`
     - Task assignment: `pai-lite slot N assign <task-id> -a <adapter> -p <path>`

   **Execute or suggest (autonomy-dependent):**
   - Check: `yq eval '.mayor.autonomy_level.assign_to_slots' "$PAI_LITE_STATE_PATH/config.yaml"`
   - **auto**: execute via Bash (`pai-lite slot N clear ready`, `pai-lite slot N assign ...`)
   - **suggest**: include ready-to-run commands in the briefing
   - **manual**: include observations only

6. **Write result**:
   - Write briefing to `$PAI_LITE_STATE_PATH/briefing.md`
   - Write result JSON to `$PAI_LITE_RESULTS_DIR/$PAI_LITE_REQUEST_ID.json`

7. **Commit and push state**:
   - Run `pai-lite sync` to commit and push to remote

## Output Format

### briefing.md

```markdown
# Briefing - YYYY-MM-DD

## Current State
- Slot 1: [task] (agent-duo, phase)
- Slot 2: empty
- ...

## Slot Assignments
- Slot 2: <- task-101 "Implement tensor concatenation" (A-priority, unblocks 2 tasks)
- Slot 4: <- ocannl project (unclassified claude-code session on ~/repos/ocannl/)
- Slot 5: cleared task-089 (stalled 12 days) <- task-067 "Update CHANGES.md" (release blocker)
- [If autonomy=suggest, include ready-to-run commands:]
  `pai-lite slot 2 assign task-101 -a agent-duo -p ~/repos/ocannl`

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

- **Pre-computed data** in `briefing-context.md` (no CLI commands needed for data gathering)
- **Task tool** to invoke `/pai-elaborate` for unprocessed tasks (parallel)
- **CLI tools** for slot operations (`pai-lite slot N assign`, `pai-lite slot N clear`)
- **Direct analysis** for strategic reasoning, slot assignment trade-offs, suggestions

## Error Handling

If state files are missing or malformed:
- Write partial briefing with warnings
- Include "run pai-lite tasks sync" suggestion
- Still write result JSON with status "partial"
