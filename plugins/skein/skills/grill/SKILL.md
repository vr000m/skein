---
name: grill
description: "Runs a relentless, one-question-at-a-time interview over any plan, design, or freeform idea, splitting facts (verified from the codebase, never asked) from decisions (genuine judgment calls that must go to the human). Proposes one recommended resolution per decision and blocks until the user accepts, proposes an alternative, or waives it before advancing. Works standalone against a plan file or inline conversational input — not gated behind having run /review-plan first. Use when the user says 'grill me on X', 'stress-test this plan', 'interview me on this design', or '/grill'."
argument-hint: "[path/to/plan.md] | [freeform description]"
---

# Grill: Relentless Fact/Decision Interview

Grill a plan, design, or freeform idea one question at a time. Every candidate question is first sorted into a **fact** (verifiable from the codebase — look it up, never ask) or a **decision** (a genuine judgment call with no single correct answer — must go to the human). For each decision, propose exactly one recommended resolution and block until the user answers before moving to the next one. No batching, no undifferentiated option lists.

This skill is inspired by mattpocock/skills' `grilling` skill, as described in conversation — its upstream source is not present in this codebase and has not been verified directly; this is a freshly authored implementation of that idea, not a port.

This document has two independently-anchored sections:

- **§ Interview Mechanics** — the reusable interview protocol (fact/decision split, one recommendation per decision, strict serial pacing, three-way accept/override/waive outcome). `/review-plan` Step 6.4 references this section inline, in-session, for the findings it classifies as grill-eligible — it does not activate this skill or spawn a subagent to do so.
- **§ Target Acquisition & Persistence** — standalone-invocation only: target parsing (plan file vs freeform), the review-marker refusal check, and where resolved decisions get persisted (`/dev-plan update` or a conversational summary). Step 6.4 never runs this section: it already knows its target (the plan under active review) and its persistence route (`/dev-plan update`, its own Route sub-step).

## Usage

- `/grill docs/dev_plans/20260711-feature-foo.md` — grill an existing plan file
- `/grill I'm thinking of adding a Redis cache in front of the auth service` — grill a freeform idea typed directly in the conversation
- "grill me on this design" / "stress-test this plan" — natural-language triggers, same behavior

## § Interview Mechanics

This section assumes the caller (a standalone `/grill` invocation via § Target Acquisition & Persistence, or `/review-plan` Step 6.4 inline) has already resolved a target: a body of text (plan content or freeform description) to interview about, plus a fixed list of candidate topics/findings to work through.

### Step 1: Classify each candidate as fact or decision

For each candidate topic:

- **Fact** — answerable by reading the codebase directly (a file exists, an API's actual signature, a dependency's actual version, an existing pattern already in use elsewhere in the repo). Look it up. Never ask the user about it, and never let it consume one of the serial interview slots below.
- **Decision** — a genuine judgment call with no single correct answer derivable from the codebase alone: architecture/component-boundary trade-offs, third-party integration contracts, security posture, rate-limiting policy, naming/scope calls, or anything else where reasonable engineers could disagree. These are the only candidates that go through Step 2.

If a candidate looks like it could be resolved either way, prefer treating it as a decision — asking costs one blocking question; guessing wrong at a fact costs a silent, unverified claim baked into the interview's output. When in doubt, do not skip the ask.

### Step 2: Interview decisions one at a time, strictly serial

For each decision, in a fixed, stable order (the order the candidates were enumerated in, or the order Step 6.4 hands them over):

1. Propose **exactly one** recommended resolution — not a menu of options. State the recommendation and a one-sentence rationale grounded in what was actually found in the codebase or the target text.
2. Present a fixed three-way choice for that recommendation:
   - **Claude**: `AskUserQuestion` with exactly three options — **accept**, **propose an alternative**, **waive**.
   - **Codex**: an equivalent plain-text three-way prompt (no `AskUserQuestion`-equivalent widget exists on Codex), per the harness-divergence precedent already established for `/review-plan`'s Clarify sub-step (`plugins/skein/skills/review-plan/SKILL.md:521-527`).
3. If the user picks **propose an alternative**, follow up with a free-text prompt to capture the override — mirroring Clarify's existing free-text path for findings with no clear fixed options.
4. Record the outcome for that decision as one of: `accept` (the recommendation as proposed), `override` (the user's free-text alternative), or `waive`.
5. **Block until this decision is answered before presenting the next one.** Do not batch multiple decisions into a single prompt, and do not advance past an unanswered decision.

### Step 3: Hand off resolved outcomes

Once every decision candidate has an outcome (`accept` / `override` / `waive`), hand the full set of outcomes back to the caller:

- Standalone invocation → § Target Acquisition & Persistence, below.
- `/review-plan` Step 6.4 → its own Route sub-step, which calls `/dev-plan update` for `accept`/`override` outcomes (prefixed `Decision (grilled): <what to change and why>`) and routes `waive` outcomes to `### Review Waivers`, exactly as documented in `review-plan/SKILL.md`.

§ Interview Mechanics never calls `/dev-plan update` itself and never decides where waived items go — persistence and routing are the caller's responsibility (§ Target Acquisition & Persistence, below, for the standalone case).

## § Target Acquisition & Persistence

This section runs only for a standalone `/grill` invocation. `/review-plan` Step 6.4 never reaches this section.

### Step 1: Resolve the target

- If the argument is a path to an existing file (most commonly `docs/dev_plans/*.md`, but any markdown/text file is accepted), read it in full — it is the target.
- Otherwise, treat the argument (or the surrounding conversational message, when invoked via natural language rather than `/grill <path>`) as freeform inline text — the description of the plan/design/idea itself, with no backing file.

### Step 2: Marker-refusal check (plan-file targets only)

If the target is a `docs/dev_plans/*.md` file, check whether `/review-plan` has already written its review marker (`<!-- reviewed: YYYY-MM-DD @ <hash> --> `, per `plugins/skein/skills/review-plan/SKILL.md`'s marker format) above the `## Progress` divider.

- **Marker present**: refuse to run the interview by default. Tell the user the plan has already been reviewed and accepted, and that grilling it now would silently reopen a contract that's already been signed off. Require an explicit acknowledgement from the user (e.g. "yes, re-open it anyway") before proceeding. This mirrors the posture `/review-plan` itself takes toward re-reviewing already-marked plans — below-marker workspace edits (`## Progress`, `## Findings`) are always fine and never trigger this check; it is only above-marker contract content this guards.
- **No marker yet** (or a template placeholder divider with no marker): proceed directly to § Interview Mechanics, Step 1, using the plan's candidate list (Requirements, Technical Specifications, Architecture Decisions, or — for a fresh plan with no prior findings — topics the user names or that stand out on a read-through).

### Step 3: Run the interview

Hand the resolved target and its candidate list to § Interview Mechanics. Do not re-run or duplicate its protocol here.

### Step 4: Persist resolved decisions

- **Target is a `docs/dev_plans/*.md` plan file**: for each `accept`/`override` outcome, call `/dev-plan update` with a prose summary of the decision (what to change and why, not an inline diff), prefixed `Decision (grilled): <what to change and why>`. `/dev-plan update` weaves it into the plan above the marker (Technical Specifications), the same route Step 6.4 uses. This is a fresh, standalone `/dev-plan update` call — there is no active `/review-plan` Step 6.4 loop to be "this loop's" writer for, since standalone `/grill` runs independently of `/review-plan`. `waive` outcomes are not written back to the plan file; summarize them in conversation only.
- **Target is freeform inline text with no backing plan file**: do not call `/dev-plan update` — there is nothing to update. Summarize every resolved decision (`accept`/`override`/`waive`) back in the conversation, and offer to run `/dev-plan create` if the user wants the resolved design persisted as a plan.
