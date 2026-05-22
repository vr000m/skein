# deep-review Skill

| Field | Value |
|-------|-------|
| **Status** | In Progress |
| **Component** | review-skills |
| **Priority** | High |
| **Branch** | `feature/deep-review` |
| **Created** | 2026-03-17 |
| **Objective** | Create a `/deep-review` skill that spawns parallel subagents with clean context to perform thorough, multi-lens code review — catching issues that single-pass, context-polluted reviews miss |

## Context

Current review workflow relies on Claude's built-in `/review` and `/security-review`, run manually (often multiple times) within a conversation whose context is polluted by implementation history. The model that wrote the code is biased when reviewing it. Across projects (code-mcp, kai-pipecat), this results in 2-3 manual review rounds to surface all issues.

gstack (github.com/garrytan/gstack) demonstrates the value of cognitive mode separation — distinct skills for distinct phases. Their `/review` uses two-pass analysis, structured checklists, and Greptile triage. We adapt these ideas but go further: parallel lens-based subagents with clean context and a feedback loop that updates project knowledge.

**Key design principle:** `/deep-review` complements the built-in `/review` and `/security-review` — it does not wrap or replace them. Users can run either or both.

## Requirements

1. Spawn parallel subagents (clean context, no parent conversation history) for thorough review
2. Each subagent reviews through a specific lens (logic, security, spec compliance, architecture, documentation)
3. Findings include severity, category, file:line, evidence, and actionable suggestion
4. Suppress previously-dismissed findings using AGENTS.md `## Review Checklist`
5. Flag documentation gaps alongside code issues
6. Consolidated report presented to main context for triage
7. Triage outcomes (won't-fix, analysis-error) feed back into AGENTS.md `## Review Checklist`
8. Dev-plan template gains a `## Review Focus` section for author-specified review criteria (including spec references)
9. Works across project types (Python, JS/TS, shell, mixed)
10. Coexists with built-in `/review` and `/security-review` — distinct name, distinct purpose
11. Cost-appropriate model assignment per lens (opus for deep analysis, sonnet/haiku for lighter tasks)
12. Partial failure handling with `--continue` flag to retry only failed lenses

## Implementation Checklist

### Phase 1: Core skill — `.claude/skills/deep-review/SKILL.md`
- [x] Create skill file with frontmatter (name, description, argument-hint)
- [x] Define input resolution: explicit path/PR > current branch diff > ask user
- [x] Define 5 review lenses with per-lens subagent prompts:
  - [x] **Logic lens** (model: opus): off-by-one, edge cases, error handling, race conditions, resource leaks
  - [x] **Security lens** (model: opus): OWASP top 10, input validation, secrets exposure, auth/authz
  - [x] **Spec compliance lens** (model: opus): RFC/standard conformance — only runs when dev-plan `## Review Focus` lists specs/RFCs
  - [x] **Architecture lens** (model: sonnet): coupling, API surface, backward compat, naming, patterns
  - [x] **Documentation lens** (model: haiku): stale docs, missing coverage, plan-vs-implementation drift, README/AGENTS.md gaps
- [x] Define finding format: severity (Critical/Important/Minor), category, file:line, evidence, suggestion
- [x] Define triage flow: findings → main context → fix / won't-fix (+ why) / analysis-error (+ correction)
- [x] Define feedback loop: won't-fix and analysis-error outcomes update AGENTS.md `## Review Checklist`
- [x] Define suppression: before presenting, check AGENTS.md `## Review Checklist` for previously-dismissed patterns
- [x] Define deduplication: when multiple lenses flag the same file:line, keep the higher-severity finding and note the overlap
- [x] Define `--continue` flag: retry only lenses that failed/timed out in the previous run, merge with prior results
- [x] Define `--full` flag (default): run all lenses fresh
- [x] Define persisted run state: `.deep-review/latest.json` (gitignored) stores lens status, findings, snapshot identity (base/head commits, diff hash), and run metadata for `--continue`
- [x] Add `.deep-review/` to `.gitignore`
- [x] Define cost confirmation: before spawning, show user which lenses will run with which models, ask to proceed
- [x] Subagent mechanism: use Claude Code's built-in Agent tool (like `/review-plan`), NOT CLI spawning — no worktrees needed since all lenses review the same codebase in place

### Phase 2: Dev-plan template update
- [x] Add `## Review Focus` section to `.claude/skills/dev-plan/template.md`
- [x] Section is optional but encouraged — author-specified criteria that `/deep-review` and `/review-plan` consume
- [x] Must include spec/RFC references if applicable (this is how the spec compliance lens knows to activate)
- [x] Examples: "SDP must comply with RFC 3264", "no plaintext credentials in signaling", "backward compat with v2 API"

### Phase 3: AGENTS.md convention
- [x] Document that repos should add `## Review Checklist` to their repo-root AGENTS.md
- [x] Checklist contains: project-specific gotchas, known false positives, won't-fix patterns with reasons
- [x] `/deep-review` reads this section; triage outcomes update it
- [x] Add initial `## Review Checklist` section to this repo's AGENTS.md as an example
- [x] Strict format: `- **[Category] disposition**: description (date)` — one finding per bullet, stable wording, machine-parseable for reliable suppression by both Claude and Codex

### Phase 4: Script integration
- [x] Add `deep-review` to `MANAGED_SKILLS` in `promote-skills.sh`
- [x] Add `deep-review` to `MANAGED_SKILLS` in `sync-skills.sh`
- [x] Add `deep-review` to `MANAGED_SKILLS` in `bootstrap-skills.sh`
- [x] Add `deep-review` to `MANAGED_SKILLS` in `check-sync.sh`
- [x] Add `deep-review` to `.env.example`

### Phase 5: Documentation
- [x] Add `deep-review` row to README.md skills table
- [x] Update repo-root AGENTS.md skill workflow section (add `/deep-review` after implementation, before merge)
- [x] Update dev_plans/README.md with this plan entry

### Phase 6: Codex tasks (Codex handles independently)
Codex should independently create/update the following to match its own harness conventions:
- [x] Create `.codex/skills/deep-review/SKILL.md` — adapted from Claude version for Codex's model/platform
- [x] Update `.codex/skills/dev-plan/template.md` — add `## Review Focus` section
- [x] Update `.codex/skills/dev-plan/SKILL.md` — mention `## Review Focus` as a section to produce when creating plans (template alone isn't enough if SKILL.md doesn't reference it)
- [x] Update `.codex/skills/review-plan/SKILL.md` — add `## Review Focus` to the extraction list so `/review-plan` consumes author-specified spec/RFC criteria
- [x] Update `.codex/AGENTS.md` — add `/deep-review` to Skill Workflow section
- [x] Use Codex-appropriate model IDs (not Claude model names)

**Note:** Do not directly edit `.codex/skills/` — it's a mirror managed by sync scripts. Codex handles its own side.

## Technical Specifications

### Files to Create
| File | Purpose |
|------|---------|
| `.claude/skills/deep-review/SKILL.md` | Core skill definition with lens prompts and triage flow |
| `.deep-review/latest.json` | Persisted run state for `--continue` (gitignored, created at runtime) |

### Files to Modify
| File | Change |
|------|--------|
| `.claude/skills/dev-plan/template.md` | Add `## Review Focus` as optional section in plan template |
| `.claude/skills/review-plan/SKILL.md` | Add `## Review Focus` to the extraction list so `/review-plan` consumes spec/RFC criteria |
| `AGENTS.md` (repo root) | Add `## Review Checklist` section; update skill workflow |
| `README.md` | Add deep-review to skills table |
| `scripts/promote-skills.sh` | Add `deep-review` to `MANAGED_SKILLS` |
| `scripts/sync-skills.sh` | Add `deep-review` to `MANAGED_SKILLS` |
| `scripts/bootstrap-skills.sh` | Add `deep-review` to `MANAGED_SKILLS` |
| `scripts/check-sync.sh` | Add `deep-review` to `MANAGED_SKILLS` |
| `.env.example` | Add `deep-review` to `MANAGED_SKILLS` |
| `docs/dev_plans/README.md` | Add this plan to task table |
| `.gitignore` | Add `.deep-review/` entry |

### Architecture Decisions

**Parallel lenses vs sequential cycles:**
Parallel lenses (multiple subagents, each reviewing through a different lens) outperform sequential cycles (one agent reviewing N times) because:
- Each lens has clean context optimized for its domain
- Parallelism is faster than sequential re-reviews
- Diminishing returns in sequential passes (80/15/4% rule) — different lenses catch different *categories*

**Subagent mechanism:**
Uses Claude Code's built-in Agent tool (same as `/review-plan`), NOT CLI-level spawning (unlike `/fan-out`). Rationale: all lenses review the same codebase in place — no worktrees or process isolation needed. Agent tool provides clean context naturally via `subagent_type: general-purpose`.

**Cost-tiered model assignment:**
Not all lenses need the same model. Assign based on analysis depth:
| Lens | Model | Rationale |
|------|-------|-----------|
| Logic | opus | Requires deep reasoning about edge cases and race conditions |
| Security | opus | Security bugs are high-impact; worth the investment |
| Spec compliance | opus | RFC conformance requires careful cross-referencing |
| Architecture | sonnet | Pattern matching and coupling analysis; less deep reasoning |
| Documentation | haiku | Checking doc freshness is mostly mechanical comparison |

**Lens activation:**
Not all lenses run every time:
- Logic, Architecture, Documentation: always run
- Security: always run (lightweight when no security-relevant changes)
- Spec compliance: only when the dev-plan `## Review Focus` explicitly lists specs/RFCs — the skill does NOT guess

**Partial failure and re-run behavior:**
```
/deep-review          → run all lenses (default = --full)
/deep-review --full   → run all lenses (explicit)
/deep-review --continue → retry only failed/timed-out lenses from last run, merge with prior results
```
- Timeouts: present partial results immediately with a note listing which lenses didn't complete
- No silent skipping — if a lens didn't run, the report says so explicitly
- `--continue` prevents permanently slow lenses from being silently abandoned

**Persisted run state:**
`--continue` requires knowing what happened last run. State is stored in `.deep-review/latest.json` (gitignored):
```json
{
  "run_id": "2026-03-17T14:30:00Z",
  "base_commit": "abc1234",
  "head_commit": "def5678",
  "diff_hash": "sha256:...",
  "lenses": {
    "logic": { "status": "completed", "model": "opus", "findings": [...] },
    "security": { "status": "timed_out", "model": "opus", "findings": [] },
    "spec": { "status": "skipped", "reason": "no specs in Review Focus" },
    "architecture": { "status": "completed", "model": "sonnet", "findings": [...] },
    "documentation": { "status": "completed", "model": "haiku", "findings": [...] }
  }
}
```
- `base_commit` / `head_commit`: the merge-base and HEAD at time of run
- `diff_hash`: SHA-256 of the diff content — fast staleness check
- `--continue` reads this file, compares current `head_commit` and `diff_hash`:
  - **Match**: re-run only `timed_out` or `errored` lenses, merge with prior findings
  - **Mismatch**: warn "diff has changed since last run" and fall back to `--full`
- `--full` overwrites the file
- File is gitignored — not committed, local-only
- If file is missing, `--continue` falls back to `--full` with a warning

**Cost confirmation:**
Before spawning subagents, show the user:
```
Deep review will run 4 lenses:
  Logic (opus), Security (opus), Architecture (sonnet), Documentation (haiku)
  Spec compliance: skipped (no specs in Review Focus)
Proceed? [Y/n]
```

**Triage feedback loop:**
```
Finding → User triages:
  ├── "Fix" → user/agent fixes the code
  ├── "Won't fix" → reason recorded in AGENTS.md ## Review Checklist
  │   (future deep-reviews suppress this pattern with a note)
  └── "Analysis error" → correction recorded in AGENTS.md ## Review Checklist
      (future deep-reviews avoid this false positive)
```

**Deduplication:**
When multiple lenses flag the same file:line:
- Keep the finding with higher severity
- Note which other lenses also flagged it (adds confidence)
- Don't present the same issue twice

**Dismissed pattern storage:**
Dismissed patterns live in repo-root AGENTS.md `## Review Checklist`, not in separate memory files.

Strict format — one finding per bullet, machine-parseable for reliable suppression:
```markdown
## Review Checklist
- **[Security] won't-fix**: raw SQL in migration scripts is intentional (2026-03-17)
- **[Architecture] analysis-error**: singleton in transport.py is by design, not coupling (2026-03-17)
```
Pattern: `**[Category] disposition**: description (date)`
- Category: one of Logic, Security, Spec, Architecture, Documentation
- Disposition: one of `won't-fix`, `analysis-error`
- Description: stable wording, specific enough to match future findings
- Date: ISO date when added

This keeps all project knowledge in one place (AGENTS.md) rather than split across AGENTS.md + memory files. The strict format ensures both Claude and Codex can reliably grep and suppress matching patterns.

**Relationship to existing skills:**
```
/dev-plan create → /review-plan → implement → /deep-review → /update-docs → merge
                                                    ↕
                                        /review + /security-review
                                        (can run independently anytime)
```

### Integration Seams

| Seam | Producer | Consumer | Contract |
|------|----------|----------|----------|
| Dev plan Review Focus | `/dev-plan` | `/deep-review`, `/review-plan` | Optional `## Review Focus` section with bullet list of criteria; must list specs/RFCs for spec compliance lens to activate |
| AGENTS.md Review Checklist | User/triage | `/deep-review` | `## Review Checklist` section in repo-root AGENTS.md with dismissed patterns |
| Finding format | Lens subagents | Main context triage | Severity/category/file:line/evidence/suggestion structure |

## Review Focus

- [x] Subagent prompts must be self-contained — no references to parent context
- [x] Each lens prompt must specify what to look for AND what to ignore (scope boundaries)
- [x] Finding deduplication logic must handle overlapping categories (e.g., a security issue that's also a logic issue)
- [x] AGENTS.md changes must not break existing sections or sync workflow
- [x] Dev-plan template change must be backward compatible (Review Focus is optional)
- [x] The skill must work on repos that have no AGENTS.md or no Review Checklist section (graceful degradation)
- [x] Spec compliance lens must NOT guess — only activates when Review Focus explicitly lists specs/RFCs
- [x] Cost confirmation must appear before spawning subagents

## Testing Notes

### Manual testing plan
1. Run `/deep-review` on this repo's own PR (self-referential test)
2. Run `/deep-review` on a pipecat PR with protocol code and Review Focus listing RFCs (tests spec compliance lens activation)
3. Run `/deep-review` on a project with no AGENTS.md (tests graceful degradation)
4. Verify triage flow: accept a finding, won't-fix a finding, flag an analysis error
5. Verify suppression: run again after won't-fix, confirm suppressed finding noted but not resurfaced
6. Verify partial failure: simulate a lens timeout, confirm partial results presented with note
7. Verify `--continue`: after partial failure, run with `--continue`, confirm only failed lenses re-run
8. Verify cost confirmation: confirm user sees lens/model breakdown before spawning

### Verification run
- [x] `just lint-scripts`
- [x] `git diff --check`
- [x] `./scripts/bootstrap-skills.sh --yes --force` with temp global directories
- [x] `./scripts/promote-skills.sh --yes` with temp global directories
- [x] `./scripts/sync-skills.sh` with temp global directories
- [x] `./scripts/check-sync.sh` with temp global directories
- [x] Verified `.claude/skills/deep-review/SKILL.md` and `.codex/skills/deep-review/SKILL.md` exist in the repo
- [x] Live `/deep-review` slash-command smoke run in Claude Code (self-review on this branch)
- [ ] Live `/deep-review` slash-command smoke run in Codex session

## Issues & Solutions

### Review finding: template.md vs SKILL.md
- **Problem**: Original plan targeted `.claude/skills/dev-plan/SKILL.md` for Review Focus section
- **Solution**: Corrected to `.claude/skills/dev-plan/template.md` — SKILL.md describes behavior, template.md has the section structure
- **Files affected**: Plan updated, no code change needed

### Review finding: subagent mechanism ambiguity
- **Problem**: Plan didn't specify whether to use Agent tool or CLI spawning
- **Solution**: Explicitly chose Agent tool (like `/review-plan`) — no worktrees needed since all lenses review same codebase
- **Files affected**: Plan updated

### Review finding: AGENTS.md ambiguity
- **Problem**: Plan said "AGENTS.md" without specifying repo-root vs `.codex/AGENTS.md`
- **Solution**: Clarified: repo-root AGENTS.md gets Review Checklist + workflow update. `.codex/AGENTS.md` is Codex's responsibility.
- **Files affected**: Plan updated

### Codex review: persisted state for --continue
- **Problem**: Plan didn't define where lens status and prior findings are stored for `--continue`
- **Solution**: Added `.deep-review/latest.json` (gitignored) with explicit schema — lens status, findings, run metadata
- **Files affected**: Plan updated, `.gitignore` needs entry at implementation time

### Codex review: Phase 6 missing dev-plan SKILL.md
- **Problem**: Phase 6 only updated template.md but Codex SKILL.md hard-codes required sections and wouldn't mention Review Focus
- **Solution**: Added `.codex/skills/dev-plan/SKILL.md` to Phase 6 task list
- **Files affected**: Plan updated

### Codex review: review-plan doesn't consume Review Focus
- **Problem**: Codex review-plan only extracts objective, requirements, checklist, specs, seams, acceptance criteria — not Review Focus
- **Solution**: Added `.codex/skills/review-plan/SKILL.md` to Phase 6 and `.claude/skills/review-plan/SKILL.md` to Files to Modify
- **Files affected**: Plan updated

### Codex review: --continue needs snapshot identity
- **Problem**: Merging completed-lens findings from an older snapshot with retried lenses from a newer snapshot surfaces stale results
- **Solution**: Added `base_commit`, `head_commit`, and `diff_hash` to `latest.json`. `--continue` compares current state — mismatch falls back to `--full` with a warning.
- **Files affected**: Plan updated

### Codex review: .gitignore not scheduled
- **Problem**: `.deep-review/` noted as gitignored but `.gitignore` not in Files to Modify or checklist
- **Solution**: Added `.gitignore` to both Files to Modify table and Phase 1 checklist
- **Files affected**: Plan updated

### Self-review: input resolution divergence
- **Problem**: Claude SKILL.md had 3 input resolution steps; Codex had 5 with `--pr` and plan-file support. Broke the "same interface" pattern.
- **Solution**: Aligned Claude input resolution to 6 steps matching Codex: plan-file, `--pr`, explicit target, `--continue`/`--full`, branch diff, ask user
- **Files affected**: `.claude/skills/deep-review/SKILL.md`

### Self-review: missing schema_version in latest.json
- **Problem**: `latest.json` had no schema version field. Future schema changes could cause `--continue` to silently read stale-shaped data.
- **Solution**: Added `"schema_version": 1` to schema. `--continue` falls back to `--full` on version mismatch.
- **Files affected**: `.claude/skills/deep-review/SKILL.md` (Codex side pending)

### Self-review: vague suppression matching
- **Problem**: "Do not suppress if the match is too vague" was qualitative in an otherwise machine-parseable protocol.
- **Solution**: Tightened to: "suppress only when checklist description matches file path, named symbol, or specific pattern"
- **Files affected**: `.claude/skills/deep-review/SKILL.md` (Codex side pending)

### Review finding: cost of 5 opus subagents
- **Problem**: No cost guard for spawning 5 opus subagents
- **Solution**: Tiered models (opus/sonnet/haiku by lens complexity) + cost confirmation before spawning
- **Files affected**: Plan updated

## Acceptance Criteria

- [x] `/deep-review` triggers correctly from slash command
- [x] Spawns parallel subagents with clean context (no parent history)
- [x] At least 3 lenses produce structured findings
- [x] Findings are deduplicated and sorted by severity
- [x] Previously-dismissed patterns (from AGENTS.md Review Checklist) are suppressed with a note
- [ ] Triage outcomes can be recorded in AGENTS.md Review Checklist
- [ ] Works on repos without AGENTS.md Review Checklist (graceful degradation)
- [x] Dev-plan template includes optional Review Focus section
- [x] Spec compliance lens only activates when Review Focus lists specs/RFCs
- [x] Cost confirmation shown before spawning subagents
- [ ] `--continue` retries only failed lenses and merges with prior results
- [x] Skill syncs correctly via promote/sync/bootstrap/check-sync scripts
- [x] Codex has equivalent skill adapted to its own harness (Codex handles independently)

## Final Results

*(To be filled on completion)*
