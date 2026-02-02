# /elaborate - Task Elaboration

Elaborate a high-level task into a detailed specification.

## Trigger

This skill is invoked when:
- The user runs `pai-lite mayor elaborate <task_id>`
- Before assigning a task to a slot

## Arguments

- `<task_id>`: Task identifier (e.g., `task-042`)

## Inputs

- `$PAI_LITE_STATE_PATH`: Path to the harness directory
- `$PAI_LITE_REQUEST_ID`: Request ID for writing results

## Process

1. **Read task file**:
   ```bash
   cat "$PAI_LITE_STATE_PATH/tasks/<task_id>.md"
   ```

2. **Gather context**:
   - Read related task files (dependencies)
   - Check GitHub issue if linked
   - Read project-specific memory: `mayor/memory/projects/<project>.md`
   - Identify relevant code files in the repository

3. **Elaborate**:
   - Break down into subtasks
   - Identify specific files to modify
   - Note edge cases and potential blockers
   - Add implementation hints
   - Define test cases

4. **Update task file**:
   Expand the task with detailed specification

## Output Format

### Updated Task File

The task file should be updated with additional sections:

```markdown
---
[existing frontmatter]
elaborated: 2026-02-01
---

# Context
[existing context]

# Acceptance Criteria
[refined criteria]

# Implementation Plan

## Phase 1: Parser Changes
- [ ] Modify `lib/einsum/parser.ml` to recognize `^` operator
- [ ] Add AST node for concatenation
- [ ] Update precedence rules (same as `,`)

## Phase 2: Inference
- [ ] Extend `lib/einsum/infer.ml` for concatenation projections
- [ ] Handle dimension alignment

## Phase 3: Codegen
- [ ] Update `lib/einsum/codegen.ml`
- [ ] Add runtime concatenation implementation

## Phase 4: Testing
- [ ] Add unit tests in `test/einsum_test.ml`
- [ ] Add integration test with existing benchmarks

# Technical Notes

## Code Pointers
- Parser entry point: `lib/einsum/parser.ml:142`
- Inference main: `lib/einsum/infer.ml:87`
- Similar feature: tensor product implementation at line 203

## Edge Cases
- Empty tensors
- Mismatched dimensions
- Broadcasting behavior

## Dependencies
- Requires task-041 (parser refactoring) to be complete

# Estimated Effort
Medium (2-3 days)
- Day 1: Parser + AST
- Day 2: Inference + Codegen
- Day 3: Testing + edge cases
```

### Result JSON

```json
{
  "id": "req-...",
  "status": "completed",
  "timestamp": "...",
  "output": "Elaborated task-042 with implementation plan",
  "task_id": "task-042"
}
```

## Delegation Strategy

- **Sonnet** (via Task tool): Generate structured subtasks
- **CLI**: File navigation, code search
- **Opus**: Write detailed specification with judgment calls

## Error Handling

- Task not found: Write result with status "error"
- Already elaborated: Ask if re-elaboration is wanted
- Missing context: Note gaps and proceed with available information
