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
     - Run a lightweight version of step 6 ((Re)Assign slots): only process
       newly-empty slots or newly-ready high-priority tasks — do not re-evaluate
       existing assignments
     - Skip to step 8 (Write result) after amending
   - If the dates differ or no briefing exists, proceed with the full process below

2. **Gather context**:
   - Run `pai-lite sessions report` to discover all active agent sessions and generate
     the sessions report (`sessions.md`). This scans Codex (`~/.codex/sessions/`),
     Claude Code (`~/.claude/projects/`), and tmux for sessions started by any tool.
   - Read `sessions.md` — pay special attention to **Unclassified Sessions** that
     couldn't be matched to any slot. These may need slot assignment or investigation.
   - Read `slots.md` to understand active work
   - Read `tasks/*.md` to understand task inventory
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

5. **Split work** (refine task/project granularity):

   Before assigning slots, check whether any tasks or projects should be split into
   finer-grained units. Signals that a split is warranted:

   - **Git worktrees and sub-paths**: multiple worktrees under the same repo indicate independent
     strands of work that could each occupy a slot. For example, `~/repos/ocannl/`
     and `~/repos/ocannl-einsum/` suggest splitting into sub-projects.
     If a session's cwd is a subdirectory or a
     path like `<repo>-<feature>/`, that feature strand could also be its own sub-project.
     **Exception**: worktrees that belong to the same agent-duo feature (the adapter
     creates a worktree for its working branch) should NOT be split — they are one
     unit of work.
   - **Large tasks with independent acceptance criteria**: a task with multiple
     unrelated checklist items may be better served as separate sub-tasks.

   Mechanical outcomes:
   - **Sub-projects**: create project-reserved slots with the narrower path
     (e.g., `pai-lite slot N assign "ocannl-einsum" -a claude-code -p ~/repos/ocannl-einsum`)
   - **Sub-tasks**: use `pai-lite tasks create "<title>" <project> <priority>` or
     invoke `/pai-elaborate <task-id>` to break a task into children

   This step feeds into the next — the refined inventory gives (Re)Assign slots
   more precise units to work with.

6. **(Re)Assign slots**:

   A slot can be in one of three states:
   - **Empty**: Process=(empty), Task=null — available for assignment
   - **Project-reserved**: has a Path and Mode but Task=null — reserved for a project's
     context without a specific task (e.g., "ocannl development")
   - **Task-assigned**: has a Task ID, Path, Mode — actively working on a task

   **Phase A — Identify opportunities:**
   - List empty slots (candidates for filling)
   - List slots with stalled work (in-progress >7 days without updates) or tasks that
     appear completed but still occupy a slot — candidates for clearing
   - Cross-reference with the ready queue from step 4 and unclassified sessions from step 2

   **Phase B — Build assignment plan:**
   - For each empty slot: pick the highest-priority ready task, considering context
     affinity (prefer tasks whose `context` matches neighboring active slots to minimize
     context switching cost). If no ready task fits but an unclassified session is running
     on a project path, reserve the slot for that project.
   - When all slots are occupied and a high-priority ready task needs attention: weigh
     the value of starting it against the cost of evicting the current occupant. Consider:
     priority differential, staleness of the occupant, deadline proximity of the new task.
     Evicted tasks return to `status: ready` — they are not cancelled, just removed from
     the active attention set.
   - For project-only reservations (no specific task):
     `pai-lite slot N assign "<project> development" -a <adapter> -p <path>`
     This sets Task=null because the description doesn't match task-*/gh-*/readme-* patterns.
   - For task assignments:
     `pai-lite slot N assign <task-id> -a <adapter> -p <path>`

   **Phase C — Execute or suggest (autonomy-dependent):**
   - Check the autonomy level by reading the config file:
     `yq eval '.mayor.autonomy_level.assign_to_slots' "$PAI_LITE_STATE_PATH/config.yaml"`
   - If **auto**: execute commands directly via the Bash tool:
     - To clear: `pai-lite slot N clear ready`
     - To assign: `pai-lite slot N assign <task-or-description> -a <adapter> -p <path>`
     - For reassignment: clear first, then assign (two sequential commands)
   - If **suggest**: include the ready-to-run commands in the briefing as copy-paste suggestions
   - If **manual**: include observations only (e.g., "Slot 2 is stalled, task-101 is ready")

   **Phase D — Record in briefing:**
   - Add a `## Slot Assignments` section to the briefing documenting what was
     assigned/suggested/observed and the reasoning behind each decision

7. **Generate briefing**:
   Write a strategic briefing covering:
   - **Current state**: Active slots, ongoing work
   - **Discovered sessions**: Summary of all agent sessions found on the system.
     If there are unclassified sessions, list them and suggest slot assignments
     (or note that slots need initialization). Sessions are matched to slots by
     longest-prefix cwd matching — if a session's cwd starts with a slot's path,
     it belongs to that slot.
   - **Ready tasks**: Priority-sorted list of what can start
   - **Urgent items**: Deadlines, stalled work, blockers
   - **Suggestions**: What to work on today and why
   - **Context switches**: Note if changing context is expensive

8. **Write result**:
   - Write briefing to `$PAI_LITE_STATE_PATH/briefing.md`
   - Write result JSON to `$PAI_LITE_RESULTS_DIR/$PAI_LITE_REQUEST_ID.json`

9. **Commit and push state**:
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

## Slot Assignments
- Slot 2: ← task-101 "Implement tensor concatenation" (A-priority, unblocks 2 tasks)
- Slot 4: ← ocannl project (unclassified claude-code session on ~/repos/ocannl/)
- Slot 5: cleared task-089 (stalled 12 days) ← task-067 "Update CHANGES.md" (release blocker)
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

- **CLI tools** for ready queue computation (yq, jq, tsort)
- **CLI tools** for slot operations (`pai-lite slot N assign`, `pai-lite slot N clear`)
- **Task tool** to invoke `/pai-elaborate` for unprocessed tasks (parallel)
- **Direct Opus analysis** for strategic slot assignment trade-offs and suggestions

## Error Handling

If state files are missing or malformed:
- Write partial briefing with warnings
- Include "run pai-lite tasks sync" suggestion
- Still write result JSON with status "partial"
