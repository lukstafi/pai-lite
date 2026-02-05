# /pai-context-sync - Pre-Briefing Context Aggregation

Aggregate recent activity across sources for richer briefings.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor context-sync`
- Before `/briefing` (can be chained)
- On demand for catching up after being away

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

## Process

1. **Fetch GitHub activity**:
   ```bash
   # Recent issue comments across watched repos
   for repo in $(pai-lite config projects --repos); do
     gh api "repos/$repo/issues/comments?since=$(date -d '1 day ago' -Iseconds)" \
       --jq '.[] | {repo: "'$repo'", body: .body, user: .user.login, created: .created_at}'
   done

   # Recent PR reviews
   for repo in $(pai-lite config projects --repos); do
     gh pr list --repo "$repo" --state all --json number,title,updatedAt --jq '.[] | select(.updatedAt > "'$(date -d '1 day ago' -Iseconds)'")'
   done
   ```

2. **Fetch git commits**:
   ```bash
   for project_dir in $(pai-lite config projects --dirs); do
     git -C "$project_dir" log --since="1 day ago" --oneline --all
   done
   ```

3. **Read recent notifications**:
   ```bash
   cat "$PAI_LITE_STATE_PATH/journal/notifications.jsonl" | \
     jq -s '[.[] | select(.timestamp > "'$(date -d '1 day ago' -Iseconds)'")]'
   ```

4. **Aggregate external sources** (if configured):
   - Slack via MCP (if available)
   - Email summaries (if integrated)

5. **Generate context document**:
   Write to `$PAI_LITE_STATE_PATH/context-sync.md`

## Output Format

### context-sync.md

```markdown
# Context Sync - 2026-02-01 08:00

## GitHub Activity (Last 24h)

### Issue Comments

**ocannl#127** - "Tensor concatenation"
- @contributor1: "Have you considered using ^ for the operator?"
- @contributor2: "That aligns with the mathematical notation"

**ppx-minidebug#45** - "Performance regression"
- @user: "Still seeing slow output on large traces"
- Needs attention - may need investigation

### PR Updates

**ocannl#134** - "Einsum parser refactoring"
- Status: Approved, ready to merge
- Last update: 2h ago

### New Issues

- ocannl#129: "Support for complex tensors" (needs triage)

---

## Git Activity

### ocannl
- `a1b2c3d` Fix dimension broadcasting edge case
- `e4f5g6h` Add einsum concatenation tests

### ppx-minidebug
- `i7j8k9l` Update changelog for 3.0 release

---

## Notifications (Last 24h)

- 14:30: Slot 1 PR ready
- 18:00: Health check - task-089 stalled warning
- 22:00: Build failed on ppx-minidebug main

---

## Items Requiring Attention

1. **ocannl#129**: New issue needs triage
2. **ppx-minidebug#45**: Performance complaint - investigate?
3. **ocannl#134**: PR ready to merge

## Suggested Follow-ups

- Review and merge ocannl#134
- Triage ocannl#129
- Investigate ppx-minidebug performance complaint
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "github_comments": 4,
  "pr_updates": 1,
  "new_issues": 1,
  "commits": 3,
  "notifications": 3,
  "attention_items": 3
}
```

## Integration with /briefing

The `/briefing` skill can read `context-sync.md` to provide richer context:

```markdown
# Briefing - 2026-02-01

## External Context
[Summary from context-sync.md]

## Current State
[slot status]

## Ready Tasks
[flow ready output]
```

## Delegation Strategy

- **CLI**: gh CLI for GitHub data, git for commits
- **Haiku** (via Task tool): Parse and summarize large volumes of comments
- **Opus**: Identify items requiring attention, write summary
