# Proposal: Reconcile (State Drift Detection and Repair)

## Current State

Ludics and agent-duo are both resilient by design, but both rely heavily on file protocols and long-lived process state:

- Ludics stores authoritative planning state in git-backed task and slot files, with runtime signals from adapters, Mag queue/results, session discovery, and federation heartbeats.
- agent-duo stores orchestration state in `.peer-sync/` and `.agent-sessions/`, with runtime state in tmux/ttyd/PID files and git worktrees.

Both systems can drift after crashes, interrupted cleanup, manual edits, partial restarts, or process death.

## Problem

Today we can inspect and recover manually, but there is no single deterministic command to:

1. Detect drift across state surfaces.
2. Explain impact in one report.
3. Apply safe automated repairs.
4. Record what changed.

That creates recurring operational cost and uncertainty.

## Proposal

Add a `reconcile` command family to both projects:

- `ludics reconcile ...`
- `agent-duo reconcile ...`

`reconcile` is a consistency pass that compares declared state vs observed state, reports issues, and optionally applies bounded repairs.

This proposal is inspired by Archon's state reconciliation pattern, adapted for Ludics and agent-duo's file-first architecture and operational model.

## Goals

1. Fast, deterministic drift detection.
2. Safe-by-default behavior (`--check` mode).
3. Explicit repair tiers (`--fix-safe`, `--fix-aggressive`).
4. Idempotent convergence (re-running should produce stable clean state).
5. Full audit trail of findings and actions.

## Non-Goals

1. Replacing existing orchestration commands.
2. Auto-resolving semantic git conflicts.
3. Changing task prioritization or planning policy.
4. Replacing `doctor`; `reconcile` complements it.

## CLI Design

### Ludics

```bash
ludics reconcile --check
ludics reconcile --fix-safe
ludics reconcile --fix-aggressive

# Optional flags
ludics reconcile --scope all
ludics reconcile --scope slots,tasks,sessions,mag,federation
ludics reconcile --json
ludics reconcile --max-actions 50
```

### agent-duo

```bash
agent-duo reconcile --check
agent-duo reconcile --fix-safe
agent-duo reconcile --fix-aggressive

# Session targeting
agent-duo reconcile --feature auth --check
agent-duo reconcile --all --fix-safe
agent-duo reconcile --json
agent-duo reconcile --max-actions 50
```

### Exit Codes

- `0`: No issues found, or all requested fixes succeeded.
- `1`: Issues found in `--check` mode.
- `2`: Fix mode ran, but one or more actions failed or were skipped due to safety rules.
- `64`: Invalid CLI arguments.

## Report Model

Both commands emit a common logical model.

```ts
type ReconcileSeverity = "info" | "warn" | "error";
type ReconcileFixClass = "none" | "safe" | "aggressive";
type ReconcileActionStatus = "applied" | "skipped" | "failed";

interface ReconcileIssue {
  id: string;
  scope: string;           // slots, tasks, sessions, mag, federation, ...
  check: string;           // stable check key
  severity: ReconcileSeverity;
  message: string;
  evidence?: Record<string, string | number | boolean>;
  auto_fix: ReconcileFixClass;
}

interface ReconcileAction {
  id: string;
  issue_id: string;
  class: ReconcileFixClass;
  description: string;
  status: ReconcileActionStatus;
  error?: string;
}

interface ReconcileReport {
  tool: "ludics" | "agent-duo";
  mode: "check" | "fix-safe" | "fix-aggressive";
  started_at: string;
  finished_at: string;
  issues: ReconcileIssue[];
  actions: ReconcileAction[];
}
```

Human output should summarize counts by severity/scope, then list concrete issues.

## Ludics Scope and Checks

### Scope: `slots`

Checks:

1. Slot marked active but working directory does not exist.
2. Slot assigned task does not exist.
3. Slot `in-progress` vs task frontmatter `status` mismatch.
4. Preempt stash references missing task/path.

Safe fixes:

1. Normalize slot/task status where unambiguous.
2. Mark stale active slot as interrupted with note.

Aggressive fixes:

1. Clear invalid slot assignment and preserve backup record.

### Scope: `tasks`

Checks:

1. Duplicate task IDs.
2. `blocked_by` references missing task.
3. Dependency asymmetry (`blocks` and `blocked_by` inconsistent).
4. Frontmatter parse failures.

Safe fixes:

1. Remove broken dependency edges to missing tasks.
2. Regenerate inverse edges when deterministic.

Aggressive fixes:

1. Quarantine malformed task file to `tasks/_invalid/` and preserve original.

### Scope: `sessions`

Checks:

1. Slot/session mapping references non-existent adapter/session path.
2. Session discovered as running but no slot assigned (or vice versa).
3. `.agent-sessions` links dangling.

Safe fixes:

1. Refresh generated session reports.
2. Mark stale session references without deleting worktrees.

Aggressive fixes:

1. Remove dangling registry entries after backup.

### Scope: `mag`

Checks:

1. `mag/queue.jsonl` invalid JSONL records.
2. Request IDs duplicated.
3. Request too old without result.
4. Result file exists without request.

Safe fixes:

1. Move invalid records to quarantine file with line numbers.
2. Mark stale requests as expired in results metadata.

Aggressive fixes:

1. Drop orphan results only when no matching request exists after full scan.

### Scope: `federation`

Checks:

1. Leader points to node with stale/missing heartbeat.
2. Heartbeat files older than timeout flood state.

Safe fixes:

1. Trigger deterministic re-election.
2. Prune stale heartbeats metadata (not live nodes).

Aggressive fixes:

1. Rewrite leader state from election result even if current leader file is malformed.

## agent-duo Scope and Checks

### Scope: `session-registry`

Checks:

1. `.agent-sessions/*.session` symlink target missing.
2. Session file unreadable or malformed key-value structure.

Safe fixes:

1. Remove clearly dangling session references.

Aggressive fixes:

1. Rebuild registry from discoverable root worktrees if available.

### Scope: `peer-sync`

Checks:

1. Required files missing (`phase`, `session`, `feature`, `mode`).
2. Status files missing for active phase.
3. Phase/status impossible combination.

Safe fixes:

1. Restore missing status files to conservative `error|<epoch>|reconcile reset`.

Aggressive fixes:

1. Force transition to a recoverable phase boundary (`work` or `review`) with backup.

### Scope: `worktrees`

Checks:

1. Root worktree missing but session exists.
2. Agent worktree missing.
3. Agent `.peer-sync` symlink missing or points to wrong root.

Safe fixes:

1. Repair symlinks.
2. Mark session unusable if required worktree is missing.

Aggressive fixes:

1. Remove orphan worktree dirs and stale registry entries after backup.

### Scope: `runtime`

Checks:

1. PID file points to dead process.
2. Port record points to unavailable/foreign process.
3. Stale lock directory.

Safe fixes:

1. Remove dead PID files.
2. Remove stale locks older than threshold.

Aggressive fixes:

1. Reallocate and rewrite port bundle.

### Scope: `pr-metadata`

Checks:

1. `pr-created` status but missing `.pr` URL file.
2. Merge artifacts present in non-merge phase.

Safe fixes:

1. Normalize state markers and append reconcile note.

Aggressive fixes:

1. Remove contradictory merge markers and force re-entry into merge flow.

## Safety Model

1. Default mode is non-mutating (`--check`).
2. `--fix-safe` only performs bounded, reversible, local changes.
3. `--fix-aggressive` requires explicit flag and writes backups first.
4. Path safety checks are mandatory for any delete/move action:
   - canonicalize path
   - ensure inside allowed root
   - never operate on root itself
5. `--max-actions` caps mutation count to avoid runaway repair loops.

## Backups and Audit

### Ludics

- Backups: `<harness>/reconcile/backups/<timestamp>/...`
- Audit log: `<harness>/journal/reconcile.jsonl`

### agent-duo

- Backups: `<peer-sync>/reconcile/backups/<timestamp>/...` and/or `~/.agent-duo/reconcile/backups/<timestamp>/...`
- Audit log: `~/.agent-duo/reconcile/reconcile.jsonl`

Each action appends:

- command mode and version
- issue id
- attempted action
- outcome
- error (if any)

## Integration Points

### Ludics

1. New command module: `src/reconcile.ts`.
2. Register in `src/index.ts` and usage text.
3. Optional: `doctor` runs `reconcile --check --scope all` summary.

### agent-duo

1. Add `cmd_reconcile` to `agent-duo`.
2. Add helper checks/fix functions to `agent-lib.sh`.
3. Optional: run `--check` at start of `restart` and before `run-merge`.

## Rollout Plan

### Phase 1: Detection Only

1. Implement `--check` and JSON/human reports.
2. No mutations.
3. Stabilize check set and false-positive rate.

### Phase 2: Safe Fixes

1. Implement `--fix-safe` actions.
2. Add audit logging and backup scaffolding.

### Phase 3: Aggressive Fixes

1. Implement `--fix-aggressive`.
2. Require backup precondition and strict path guards.

### Phase 4: Operationalization

1. Add docs and runbooks.
2. Optional scheduled reconcile (Ludics trigger).
3. Optional preflight hooks in agent-duo workflows.

## Test Strategy

1. Unit tests for each check with fixture directories.
2. Unit tests for safety guards (path traversal, root path, symlink edge cases).
3. Integration tests with intentionally corrupted session/task/queue state.
4. Idempotency tests: run reconcile twice and assert no new actions on second run.
5. Snapshot tests for JSON output schema stability.

## Risks

1. False positives from unconventional but valid user flows.
2. Over-repair if checks are too aggressive.
3. Performance cost on very large task/session sets.

Mitigations:

1. Start with detection-only rollout.
2. Keep fixes conservative and reversible by default.
3. Add explicit check keys and allow targeted scopes.

## Success Criteria

1. Mean time to recover from crash/state drift is significantly reduced.
2. Most common drift classes resolve via `--fix-safe`.
3. Operators trust reconcile output enough to include it in normal workflows.
4. Reconcile actions are auditable and low-risk.

## Summary

`reconcile` is a high-leverage reliability feature for both Ludics and agent-duo. It turns ad-hoc manual recovery into deterministic, testable, and auditable operations while preserving current architecture and file protocols.
