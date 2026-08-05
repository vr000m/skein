# skein

Namespaced skill plugin for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [OpenAI Codex CLI](https://github.com/openai/codex) agents. All skills load under the `skein:` namespace (`skein:dev-plan`, `skein:plan-view`, etc.) to avoid collisions with third-party skills.

## Skills

| Skill | Claude | Codex | Description |
|-------|--------|-------|-------------|
| dev-plan | Yes | Yes | Generate and manage development plans; `create` runs one fresh-context Explore subagent that gathers verified paths, patterns, dependency versions, and git refs before drafting, and drafts a conditional `## Architecture & Call Flow` section (Mermaid diagrams + context-lifecycle table, confirmed at a gate) for plans with 2+ independently-executing components |
| fan-out | Yes | Yes | Parallel agent orchestration via worktrees |
| content-draft | Yes | Yes | Draft content following style guidelines |
| content-review | Yes | Yes | Review content against style guidelines |
| deep-review | Yes | Yes | Multi-lens code review with fresh-context subagents; reconciles findings by structural signature. Opt-in `--auto-fix=trivial` applies a hard-coded allowlist of mechanical fixes (requires `--test-cmd`) |
| review-plan | Yes | Yes | Audit a dev plan via five parallel lenses (architecture, sequencing, spec-and-testing, assumptions, codebase-claims; four high-reasoning + one factual) plus one additional pass after reconciliation that detects plan-internal and cross-lens contradictions, before implementation; the architecture lens also audits negative-space topology gaps; reconciles findings by structural signature. A default-on triage-and-clarify loop records decisions into the plan before the marker is written (`--batch` skips it for CI); grill-eligible findings (architecture/component-boundary, third-party integration, security, rate-limiting, or any `Contradiction` finding) are delegated to `skein:grill`'s interview protocol instead of the standard option list. Opt-in `--auto-fix=trivial` applies allowlisted prose edits outside the immutable contract sections |
| grill | Yes | Yes | Relentless, one-question-at-a-time interview over a plan file or freeform idea; splits facts (looked up, never asked) from decisions (one recommendation each, blocks until accept/override/waive); standalone and user-invocable, also used inline by `review-plan` Step 6.4 for grill-eligible findings |
| rfc-finder | Yes | Yes | Find and link to IETF RFCs and related drafts |
| spec-compliance | Yes | Yes | Check code against RFC/W3C/WHATWG requirements |
| update-docs | Yes | Yes | Audit and update stale docs against branch diffs |
| conduct | Yes | Yes | Walk a reviewed dev plan phase by phase via harness-native clean-context subagents |
| plan-view | Yes | Yes | Generate HTML dashboard and per-plan drill-down pages from a markdown dev-plan corpus; renders Mermaid fences as live diagrams via the Mermaid CDN runtime; `--rich` mode produces LLM-rendered per-plan views constrained by a widget toolkit; deterministic and rich pages are cross-linked bidirectionally (forward links emitted unconditionally, back-links injected by `relink_rich_pages()` on every plain run) |
| review-gauntlet | Yes | Yes (partial) | Chain the review gates (adversarial review, deep-review, security-review) into one convergence loop, with fixes applied by an isolated clean-context fixer subagent; opt-in per dev plan via `**Review Gates:** none \| full`, auto-chained from `conduct` and `fan-out`. `--resume`/`--fresh` pick an interrupted run back up from a target-keyed `.gauntlet/` ledger instead of restarting the gate corpus; auto-chained invocations are self-resuming with no extra flags. `/code-review` is not a gate on the Claude side (the harness blocks Claude from self-invoking it) — run `/code-review xhigh --fix` yourself. On Codex, `/code-review` remains a native gate (unaffected), `security-review` is `deferred` (no primitive exists), and `deep-review` is gated pending nested-spawn confirmation — Codex `full` mode reports these slots explicitly rather than claiming they ran |
| release | Yes (user-invoked only) | Yes (model-invocable; no documented opt-out found; explicit pre-mutation confirmation) | Cut or re-sync a GitHub release from a `CHANGELOG.md` section: title `<repo> vX.Y.Z — <highlight>`, body = an optional `## What's New` summary paragraph + the section content with its header stripped + a `**Full diff:**` compare link; an ordinary re-sync preserves the existing highlight and `## What's New` presence/content when recoverable, making repeated re-syncs byte-identical unless the user overrides them or malformed existing content requires repair. `/release audit` scans tags, GitHub releases, and CHANGELOG versions for missing artifacts, releases whose remote tag was deleted, or drifted title/body, then reports a punch list before fixing anything |

Invoke each skill as `skein:<name>` (e.g. `skein:dev-plan`, `skein:review-plan`). Judgment lenses ("high-reasoning" above) vs. mechanical/factual work follow the two-tier model/effort policy in [AGENTS.md](AGENTS.md#modeleffort-policy-target-policy-not-yet-fully-enforced).

## Plugin install

Install through the harness plugin CLI on each machine. There are no rsync, promote, or bootstrap scripts — the marketplace files in this repo are the install surface. Both harnesses can install directly from GitHub; no clone required.

**Claude Code:**

```bash
/plugin marketplace add vr000m/skein
/plugin install skein@skein
```

**Codex CLI:**

```bash
codex plugin marketplace add vr000m/skein --ref main
codex plugin add skein@skein
```

The marketplace name `skein` matches the entries in `.claude-plugin/marketplace.json` (Claude) and `.agents/plugins/marketplace.json` (Codex). To pick up upstream changes, re-add the marketplace (or `git pull` your clone if you installed from a local path) and re-run `/plugin install skein@skein` / `codex plugin add skein@skein` — there is no separate sync step.

**Pinning to an existing release.** Tagged releases already exist through `v0.5.3`. Prefer pinning over tracking `main`: for example, pass `--ref v0.5.3` to `codex plugin marketplace add`, and check tagged releases on [the GitHub releases page](https://github.com/vr000m/skein/releases) for Claude Code (which resolves the marketplace at add time). Tracking `main` follows unreleased commits.

If you are developing against a local clone instead, swap the marketplace source for a path: `/plugin marketplace add /path/to/skein` (Claude) or `codex plugin marketplace add /path/to/skein` (Codex).

If you are migrating from the older flat layout (skills installed directly under `~/.claude/skills/` and `~/.codex/skills/`), use `scripts/delete-skills.sh` to remove the immutable 11-skill migration-era set after verifying the plugin install loads correctly. It deliberately preserves the post-migration `grill`, `release`, and `review-gauntlet` directories. The cleanup regression test is `uvx pytest tests/parity/test_delete_skills.py -q`.

## Releases

skein follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html); changes are recorded in [`CHANGELOG.md`](CHANGELOG.md) in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

Tagged releases are published on the [GitHub releases page](https://github.com/vr000m/skein/releases); the latest is **v0.5.3**. Pin an install to a specific tag with `--ref vX.Y.Z` instead of `--ref main` if you want a stable version rather than tracking `main`.

After merging a release-bearing PR and updating local `main`, use `skein:release` (`/release X.Y.Z` on Claude) to create or re-sync the tag and GitHub release. The skill previews the exact target, title, and body for confirmation before mutating remote state; do not hand-compose the old `git tag` + `gh release create` sequence.

## Setup (for contributors)

1. Install tools:

```bash
brew install just jq shellcheck shfmt
```

2. Repo invariants worth running before pushing:

```bash
just check-sync                  # canonical scripts/ ↔ bundled skill scripts byte-identity
just check-prompt-parity         # Claude vs Codex SKILL.md content parity for bundle skills
just check-trunk-snippet-parity  # trunk-resolution snippet parity
just parity-tests                # bundle + allowlist + orchestration-contract + no-fallback + marker + managed-skill/cleanup-boundary regression coverage
just reconciliation-tests        # reconciliation parity + fixture + renderer + determinism
just bundle-appliers             # regenerate bundled auto-fix pipeline inside each skill
```

## Layout

```
plugins/skein/skills/<name>/         Claude skills (SKILL.md per skill)
plugins/skein-codex/skills/<name>/   Codex skills (mirrored structure; per-harness dispatch idiom)
.claude-plugin/marketplace.json      Claude marketplace entry for skein
.agents/plugins/marketplace.json     Codex marketplace entry for skein
scripts/                             Canonical shell scripts (bundle/check/reconcile/parity/render/auto-fix)
```

See [AGENTS.md](AGENTS.md) for commands, architecture, authority model, contributor workflow, and the model/effort policy.
