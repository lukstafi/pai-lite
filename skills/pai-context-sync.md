# /pai-context-sync - Pre-Briefing Context Aggregation

Aggregate recent activity across sources for richer briefings.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor context-sync`
- Before `/pai-briefing` (can be chained)
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
# Context Sync - YYYY-MM-DD HH:MM

## GitHub Activity (Last 24h)

### Issue Comments

**repo#NNN** - "[title]"
- @user: "[comment summary]"
- [note if needs attention]

[...more if relevant...]

### PR Updates

**repo#NNN** - "[title]"
- Status: [state]
- [relevant details]

### New Issues

- repo#NNN: "[title]" (needs triage)

---

## Git Activity

### [project]
- `hash` [commit message]
- [...]

---

## Notifications (Last 24h)

- [timestamp]: [notification summary]
- [...]

---

## Items Requiring Attention

1. [Prioritized list of things needing human decision]

## Suggested Follow-ups

- [Actionable next steps]
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "github_comments": N,
  "pr_updates": N,
  "new_issues": N,
  "commits": N,
  "notifications": N,
  "attention_items": N
}
```

## Integration with /pai-briefing

The `/pai-briefing` skill can read `context-sync.md` to provide richer context:

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
