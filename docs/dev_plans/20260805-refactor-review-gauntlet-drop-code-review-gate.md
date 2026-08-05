# Drop the code-review gate from review-gauntlet (Claude side)

**Status**: Complete
**Component**: review-skills
**Branch**: feature/review-plan-contradiction-step
**Created**: 2026-08-05
**Completed**: 2026-08-05

## Why

A Claude Code harness change (see changelog: "Claude no longer runs the
`/verify` and `/code-review` skills on its own; invoke them with `/verify` or
`/code-review` when you want them") blocks `skein:review-gauntlet` from
invoking `/code-review` programmatically, regardless of its
`disable-model-invocation` frontmatter value. Gate 1 of the gauntlet is
permanently broken on the Claude side.

The Codex-side mirror (`plugins/skein-codex/skills/review-gauntlet/`) is
**not** affected — its code-review gate uses `native-codex-review` via
`codex exec review`, a different invocation path with no equivalent
restriction. Codex mirror is left unchanged.

## Decisions

1. **Remove the code-review gate entirely** from the Claude-side gauntlet.
   It becomes a 3-gate loop: adversarial Codex review (new gate 1),
   `skein:deep-review` (new gate 2), `/security-review` (new gate 3).
2. **Remove `quick` mode entirely** from the Claude-side gauntlet. It was
   defined as "gate 1 (code-review) only, single pass, no loop" — with gate 1
   gone, there's no cheap analogue worth keeping as an automated mode. The
   user runs `/code-review xhigh --fix` themselves when they want a fast
   short-circuit; that's a direct user-invoked command outside the skill,
   not something the skill can orchestrate anymore.
3. **conduct/fan-out (Claude side)** lose their own `quick`/`full` review-gate
   distinction (which forwarded `quick` to the gauntlet's now-removed quick
   mode). They always invoke the full 3-gate convergence loop.
4. **Codex-side mirror unchanged** — `native-codex-review`-based code-review
   gate, quick mode, and conduct/fan-out's Codex-side quick option all stay
   as-is.
5. **Historical dev plans left as-is** (`20260707-feature-review-gauntlet-skill.md`,
   `20260710-feature-review-gauntlet-resume.md`,
   `20260712-feature-deep-review-compact-output.md`) — this plan supersedes
   their gate-1/quick-mode structure on the Claude side only; not edited
   retroactively.

## Files to change

- `plugins/skein/skills/review-gauntlet/SKILL.md` — remove gate 1
  (code-review) section; renumber gate 2→1, 3→2, 4→3 throughout (gate
  sequence, resume/restart-from-gate-1 references, decision table, Delegation
  Pattern prose, gate matrix); remove `quick` mode section and all references
  to it; update description/title gate list.
- `plugins/skein/skills/review-gauntlet/lib/run-gate.sh` — doc-comment gate
  list, drop "code-review,".
- `plugins/skein/skills/conduct/SKILL.md` — remove `quick` review-gate
  forwarding option; always invoke full gauntlet.
- `plugins/skein/skills/fan-out/SKILL.md` — same as conduct.
- `README.md` — drop "code-review," from gate list; drop quick-mode mention.
- `AGENTS.md` — drop `/code-review` from gate-tiers description; drop
  quick-mode sentence. Leave deep-review's "four judgment lenses" (unrelated
  count) and the allowlist-fork "fourth" reference untouched.
- `tests/gauntlet/test-gauntlet-skill-shape.sh` — remove gate-1/code-review
  assertion; renumber gate 2/3/4 assertion comments to 1/2/3; remove
  `code_review_line` var and re-pin gate-order assertions to
  adversarial < deep-review < security-review; update "quick" single-pass
  assertion for new (removed) quick-mode meaning.
- `tests/gauntlet/test-codex-capability-gap-unresolved.sh` — renumber
  gate 3/4 → 2/3 (Codex-side text references only; Codex mirror content
  itself is unchanged, only if this test also greps Claude-side SKILL.md).
- `tests/gauntlet/test-conduct-hook.sh` — remove/replace
  `quick.*code-review` assertion.
- `tests/gauntlet/test-fanout-hook.sh` — same.
- `tests/gauntlet/test-review-gates-marker.sh` — same.
- `tests/gauntlet/test-run-gate.sh` — optional: rename the `"code-review"`
  fixture gate-name string to `"deep-review"` or similar so the test corpus
  doesn't imply code-review is still a live gate name (not a hard
  requirement — `run-gate.sh` treats gate names as opaque strings).

## Out of scope

- Codex-side mirror (`plugins/skein-codex/`) — no changes.
- Historical dev plans — no changes, referenced above only for context.

## Review gates

Run `/code-review xhigh --fix` yourself, plus `/security-review` and
`/deep-review`, before merge — the gauntlet itself is mid-refactor on this
branch and shouldn't be used to review itself.

## Final Results

All "Files to change" items landed as planned, plus items surfaced during
review that weren't anticipated up front:

- **Unrecognized-value guard** (not in the original plan): `conduct`/`fan-out`
  only branched on `none`/`full`, leaving a stale `quick` value or typo to
  fall through undefined. Added an explicit "unrecognized value → treated as
  `none`, with a warning naming the value and plan path" rule to both readers
  and `dev-plan/SKILL.md`'s field description, plus test coverage.
- **Codex-side dev-plan doc note** (not in the original "out of scope" list):
  `**Review Gates:**` is a shared plan-file field, and its value domain is now
  harness-dependent (`none|full` on Claude, `none|quick|full` on Codex). Added
  one clarifying sentence to `plugins/skein-codex/skills/dev-plan/SKILL.md`
  and `template.md` (via `codex:rescue`) noting `quick` is Codex-only.
- **`test-codex-capability-gap-unresolved.sh`**: no change needed — it targets
  the Codex-side SKILL.md only, which is correctly unchanged.
- **`test-run-gate.sh`**: left as-is (optional item) — the `"code-review"`
  fixture gate name is harmless, `run-gate.sh` treats gate names as opaque
  strings.
- **Self-inflicted regression, caught and fixed in-branch**: the `run-gate.sh`
  doc-comment edit was Claude-only, breaking the enforced Claude/Codex
  byte-identity parity test (`tests/parity/test-applier-bundle-parity.sh`).
  Fixed by rewording the shared comment to be harness-neutral on both mirrors.
- **`skein:deep-review` + `/security-review`** (scoped to this plan's commits
  only) also caught a mode-count contradiction ("Two modes" vs. a 3-item
  list), two dangling `/code-review`-era cross-references, and a vacuous test
  assertion — all fixed. No security findings in either pass.
- **Live verification**: temporarily repointed the installed `skein` plugin
  marketplace at this local branch (`directory` source), confirmed a fresh
  Claude Code session loaded the new 3-gate SKILL.md content with no
  `/code-review` gate and no `quick` mode, then reverted the repoint back to
  the GitHub source.

Final state: 11/11 gauntlet test files, 3/3 parity checks green. PR #24
description updated to cover this work alongside the Contradiction-Pass
feature landed earlier on the same branch.
