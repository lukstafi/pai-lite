# /ludics-feedback-digest - Workflow Feedback Digest

Read accumulated agent-duo workflow feedback, group by theme using LLM reasoning, deduplicate against existing GitHub issues, and file structured issues.

## Trigger

This skill is invoked when:
- The user runs `ludics mag feedback-digest <repo>`
- Auto-triggered by agent-duo on session completion (if `auto_digest=true`)

## Inputs

- **Argument**: GitHub repo (e.g., `owner/repo`) — passed as the first argument after the skill name
- `$LUDICS_STATE_PATH`: Path to the harness directory
- `$LUDICS_REQUEST_ID`: Request ID for writing results
- `$LUDICS_RESULTS_DIR`: Directory for result JSON

## Process

### 1. Read feedback files

Read all `.md` files from `~/.agent-duo/workflow-feedback/` (skip the `processed/` subdirectory). If no files exist, write a result indicating nothing to process and exit.

### 2. Extract individual data points

For each file, extract individual bullet points / feedback items. Track source metadata:
- Source file name (encodes date, feature, and agent)
- Category headers within the file

Delegate extraction to Haiku for speed if files are large.

### 3. Group by theme

Use LLM reasoning to cluster related items into themes. Examples of themes:
- "tmux command reliability"
- "review phase coordination"
- "worktree cleanup issues"

Each theme should have a short title and the list of data points that belong to it.

### 4. Fetch existing issues

```bash
gh issue list -R <repo> --label workflow-feedback --state open --json number,title,body --limit 100
```

### 5. Ensure label exists

```bash
gh label create workflow-feedback -R <repo> --description "Auto-filed workflow feedback from agent sessions" --color "c5def5" 2>/dev/null || true
```

### 6. Deduplicate themes against existing issues

For each theme, compare against existing open issues:
- **New theme**: No existing issue covers this topic
- **Partial overlap**: An existing issue covers related ground but the new data points add information
- **Exact match**: Existing issue already captures these points — skip

### 7. File issues or add comments

For **new themes**, create an issue:

```bash
gh issue create -R <repo> --title "<theme title>" --label workflow-feedback --body "<body>"
```

Issue body format:

```markdown
## Summary
<2-3 sentence summary of the theme>

## Data Points
- <rewritten point> (from <feature>/<agent>, <date>)
- <rewritten point> (from <feature>/<agent>, <date>)

## Raw Excerpts
<details><summary>Original feedback</summary>

> <exact quote> — <source file>

> <exact quote> — <source file>

</details>

## Suggested Action
<brief actionable suggestion for addressing this feedback>

---
*Filed by ludics-feedback-digest*
```

For **partial overlaps**, add a comment to the existing issue:

```bash
gh issue comment <number> -R <repo> --body "<comment body>"
```

Comment body format:

```markdown
## New Data Points
- <rewritten point> (from <feature>/<agent>, <date>)

## Raw Excerpts
<details><summary>Original feedback</summary>

> <exact quote> — <source file>

</details>

---
*Added by ludics-feedback-digest*
```

### 8. Move processed files

```bash
mkdir -p ~/.agent-duo/workflow-feedback/processed/
mv ~/.agent-duo/workflow-feedback/*.md ~/.agent-duo/workflow-feedback/processed/
```

### 9. Write result

Write result JSON to `$LUDICS_RESULTS_DIR/$LUDICS_REQUEST_ID.json`:

```json
{
  "id": "<request-id>",
  "status": "completed",
  "timestamp": "<ISO-8601>",
  "issues_created": 2,
  "issues_updated": 1,
  "issues_skipped": 0,
  "files_processed": 5,
  "output": "Created 2 issues, updated 1, skipped 0 (5 files processed)"
}
```

## Delegation Strategy

- **Haiku**: Extract bullet points from large feedback files, initial theme clustering
- **Opus**: Final theme grouping decisions, deduplication judgment against existing issues, writing issue summaries
- **CLI tools**: `gh` for GitHub operations, file I/O for reading/moving feedback files

## Error Handling

- If `gh` is not authenticated or the repo is inaccessible, report the error in the result JSON with `"status": "error"`
- If some issues fail to create, continue with the rest and report partial results
- Always move processed files even if some issue creation fails (to avoid re-processing)
