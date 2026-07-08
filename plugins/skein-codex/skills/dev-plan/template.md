# Development Plan Template

Use this template when creating new development plans.

---

# Task: [Title]

**Status**: Not Started | In Progress | Blocked | Complete
**Component**: [subsystem/skill area this plan touches — groups the plan in plan-view and the README index]
**Assigned to**: [Agent/Person]
**Priority**: High | Medium | Low
**Branch**: [branch-name]
**Created**: YYYY-MM-DD
**Completed**: YYYY-MM-DD (fill when done)

## Objective

[One or two sentences describing what needs to be accomplished]

## Context

[Background information explaining why this work is needed. Include:
- What problem this solves
- How it fits into the larger project
- Any relevant history or prior attempts]

## Requirements

[Specific requirements and constraints for this work]

- Requirement 1
- Requirement 2
- Requirement 3

## Review Focus

[Optional review criteria for `/review-plan` and `/deep-review`. Include spec or RFC references here if they matter.]

- Focus item 1
- Focus item 2
- RFC/spec references, if applicable

## Implementation Checklist

The Implementation Checklist is part of the **immutable contract** above the review marker. Phase blocks describe what the work is — the contract slots `/conduct` reads to decide how to spawn subagents and run tests. They MUST NOT be edited during a run; per-phase progress and findings live in the workspace section below the marker so editing them does not invalidate the marker.

Each phase SHOULD include a short contract block directly under the heading. Fill the slots in **every** phase you expect `/conduct` to execute — a phase with no slots falls through to degraded mode (sequential spawn + test fallback) and forfeits the parallel implementer/test-writer split.

- `**Impl files:**` — comma-separated paths or globs the implementer will touch (e.g., `src/foo.py, src/bar/*.ts`)
- `**Test files:**` — comma-separated paths or globs the test-writer will create/modify
- `**Test command:**` — the single canonical test invocation for this phase, in backticks (e.g., ``**Test command:** `pytest tests/test_foo.py -v` ``)
- `**Validation cmd:**` *(optional)* — a post-test check that runs after tests pass, before the boundary commit, in backticks (e.g., ``**Validation cmd:** `python scripts/reprocess_and_diff.py --ids X,Y` ``). Failure hands back to the user rather than triggering a fix loop. Use for reprocess-and-diff against a live DB, staging API probes, or other behaviour an implementer cannot auto-repair.
- `**Goal:**` *(optional)* — a 1-2 line statement of the phase's design intent, invariant, or quality bar, in plain prose (not backticked), e.g. `**Goal:** Marker hash must cover contract bytes only; workspace edits never invalidate it.` Sits above the review marker as part of the immutable contract — adding or editing it after `/review-plan` invalidates the marker hash and forces re-review, same as any other contract-slot edit. Absent `**Goal:**` is a no-op — the phase behaves exactly as today. `/conduct` injects it into the implementer and test-writer prompts as `{{PHASE_GOAL}}`, and `review-gauntlet`'s fixer reads it as the authoritative design intent for its quarantine-vs-fix decision.

If `Impl files:` and `Test files:` overlap, `/conduct` falls back to sequential spawning for that phase. If any slot is absent, `/conduct` falls back to safe defaults (sequential spawn, resolve test command from repo defaults or `--test-cmd`). If *every* unfinished phase is missing every slot, `/conduct` emits a degraded-mode warning on the first handback.

Phase task descriptions are plain bullets, not checkboxes — completion lives in the `## Progress` section below the marker, keyed by phase label.

### Phase 1: [Phase Name]

**Impl files:** `path/to/foo.ts, path/to/bar.ts`
**Test files:** `tests/test_foo.ts`
**Test command:** `npm test -- tests/test_foo.ts`
**Validation cmd:** `npm run smoke -- --env staging`
**Goal:** [Optional 1-2 line design intent / invariant this phase must hold]

- Task 1
- Task 2
- Task 3

### Phase 2: [Phase Name]

**Impl files:** `...`
**Test files:** `...`
**Test command:** `...`

- Task 1
- Task 2

### Phase 3: [Phase Name] (if needed)

**Impl files:** `...`
**Test files:** `...`
**Test command:** `...`

- Task 1
- Task 2

## Technical Specifications

### Files to Modify
- `path/to/file1.ts` - [what changes]
- `path/to/file2.ts` - [what changes]

### New Files to Create
- `path/to/new-file.ts` - [purpose]

### Architecture Decisions
- Decision 1: [rationale]
- Decision 2: [rationale]

### Dependencies
- [Any new dependencies or integrations]

### Integration Seams

Cross-component boundaries where one task's output feeds into another's input.
Fill this in before using `/fan-out` — it tells each agent what contracts to honor
and tells the merge phase what to verify.

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| [e.g., cleanup on refresh] | [IndexStore] | [cli.py] | [Must delete stale records before upsert] |

For each seam, consider: who calls it, resource lifecycle (open/close), error paths, and idempotency.

## Architecture & Call Flow

<!-- Include only when the plan has 2+ independently-executing components. Omit for single-component changes. -->

> **Conditional section.** Include only when the system has **2 or more independently-executing
> components** (e.g., Claude SDK, LLM router, MCP server, subagent, CLI, storage layer). Omit the
> section entirely for single-component changes (a typo fix, an isolated script tweak). This section
> sits **above the review marker** — it is part of the immutable contract, so editing it after
> `/review-plan` invalidates the marker hash (topology errors are plan errors, not runtime fixups).

Component graph — which component triggers which:

```mermaid
graph LR
    A[Component A] -->|triggers| B[Component B]
    B -->|reads| C[Storage layer]
```

Trigger order — the sequence of calls across a single run:

```mermaid
sequenceDiagram
    participant U as User
    participant A as Component A
    participant B as Component B
    U->>A: invoke
    A->>B: dispatch
    B-->>A: result
```

Context lifecycle — what enters context at each step, and whether it clears or persists:

| Step | Trigger | Enters context | Cleared/persisted | Turn boundary |
|------|---------|----------------|-------------------|---------------|
| 1 | [e.g., `/cmd` invoked] | [user request, repo basics] | [persists to file] | [after X written] |
| 2 | [subagent dispatched] | [prompt + codebase] | [fresh/isolated context] | [subagent completes] |

## Testing Notes

### Test Approach
- [ ] Unit tests for [component]
- [ ] Integration tests for [flow]
- [ ] Manual testing of [scenario]

### Test Results
- [ ] All existing tests pass
- [ ] New tests added and passing
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] Edge case 1
- [ ] Edge case 2

## Acceptance Criteria

- Criterion 1 - [specific, measurable outcome]
- Criterion 2 - [specific, measurable outcome]
- Criterion 3 - [specific, measurable outcome]
- Code reviewed and approved
- Tests passing
- Documentation updated (if applicable)

<!-- reviewed: YYYY-MM-DD @ <hash> -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

Per-phase completion tracked here so ticking a box during a run does not bust the review marker. `/conduct` reads this section to skip already-done phases. Format: `- [ ] Phase <label>: <title>`.

- [ ] Phase 1: [Phase Name]
- [ ] Phase 2: [Phase Name]
- [ ] Phase 3: [Phase Name]

## Findings

Durable notes that survive after the run: diagnostic query results (with explicit filters stated), decision rationale, "checked / accepted behaviour" outcomes. Group by phase if useful.

- (append findings here as work proceeds)

## Issues & Solutions

### Issue 1: [Brief description]
- **Problem**: [What went wrong]
- **Solution**: [How it was resolved]
- **Files affected**: [List files]

## Final Results

[Fill this section when the work is complete]

### Summary
[Brief summary of what was accomplished]

### Outcomes
- Outcome 1
- Outcome 2

### Learnings
- [Any insights or lessons learned during implementation]

### Follow-up Work
- [Any related work identified for future plans]
