# /pai-read-inbox - Process Inbox Messages

Read and act on asynchronous messages from the user.

## Trigger

This skill is invoked when:
- A `message` action is queued (user ran `pai-lite mayor message "..."`)
- No other skill was already queued to handle the inbox

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results
- `$PAI_LITE_RESULTS_DIR`: Directory for writing result JSON

## Process

1. **Read inbox**: Run `pai-lite mayor inbox` to consume pending messages.
   The command prints messages, archives them to `mayor/past-messages.md`, and clears the inbox.

2. **Act on messages**: For each message, determine the appropriate action:
   - **Information updates** (deadline changes, priority shifts): Update the relevant task files or context
   - **Requests** (analyze issue, elaborate task): Queue the appropriate action or handle inline
   - **Context notes** (reminders, preferences): Note in `mayor/context.md` if persistent
   - **Ambiguous messages**: Journal the message and note it for the next briefing

3. **Journal**: Record consumed messages and actions taken:
   ```bash
   pai-lite journal  # Append to today's journal
   ```

4. **Write result**:
   - Write result JSON to `$PAI_LITE_RESULTS_DIR/$PAI_LITE_REQUEST_ID.json`

## Output Format

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "messages_processed": N,
  "actions_taken": ["updated task-042 deadline", "noted priority change"]
}
```

## Delegation Strategy

- **CLI tools**: `pai-lite mayor inbox` for message consumption
- **Opus**: Interpret messages, decide actions, update files
