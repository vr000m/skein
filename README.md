# skein

[![GitHub release](https://img.shields.io/github/v/release/vr000m/skein)](https://github.com/vr000m/skein/releases)

Namespaced skill plugin for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [OpenAI Codex CLI](https://github.com/openai/codex) agents. All skills load under the `skein:` namespace (`skein:dev-plan`, `skein:plan-view`, etc.) to avoid collisions with third-party skills.

## Skills

| Skill | Claude | Codex | Pi | Description |
|-------|--------|-------|----|-------------|
| dev-plan | Yes | Yes | Yes | Generate and manage development plans; `create` runs one fresh-context Explore subagent that gathers verified paths, patterns, dependency versions, and git refs before drafting, and drafts a conditional `## Architecture & Call Flow` section (Mermaid diagrams + context-lifecycle table, confirmed at a gate) for plans with 2+ independently-executing components |
| fan-out | Yes | Yes | No (excluded) | Parallel agent orchestration via worktrees |
| content-draft | Yes | Yes | Yes | Draft content following style guidelines |
| content-review | Yes | Yes | Yes | Review content against style guidelines |
| deep-review | Yes | Yes | Yes | Multi-lens code review with fresh-context subagents; reconciles findings by structural signature, after setting `Decision candidate:` advice aside so it never merges into a same-line finding. Its Documentation Lens flags added excuse, stale, tautology and decision-candidate comments. Opt-in `--auto-fix=trivial` applies a hard-coded allowlist of mechanical fixes (requires `--test-cmd`). `--report` writes an opt-in throwaway HTML report (Claude and Codex, not Pi). The architecture lens also checks the work against the active decision records in `docs/decisions/` that match the changed paths |
| review-plan | Yes | Yes | Yes | Audit a dev plan via five parallel lenses (architecture, sequencing, spec-and-testing, assumptions, codebase-claims; four high-reasoning + one factual) plus one additional pass after reconciliation that detects plan-internal and cross-lens contradictions, before implementation; the architecture lens also audits negative-space topology gaps; reconciles findings by structural signature. A default-on triage-and-clarify loop records decisions into the plan before the marker is written (`--batch` skips it for CI); grill-eligible findings (architecture/component-boundary, third-party integration, security, rate-limiting, or any `Contradiction` finding) are delegated to `skein:grill`'s interview protocol instead of the standard option list. Opt-in `--auto-fix=trivial` applies allowlisted prose edits outside the immutable contract sections. The architecture lens also checks the work against the active decision records in `docs/decisions/` that match the changed paths |
| grill | Yes | Yes | Yes | Relentless, one-question-at-a-time interview over a plan file or freeform idea; splits facts (looked up, never asked) from decisions (one recommendation each, blocks until accept/override/waive); standalone and user-invocable, also used inline by `review-plan` Step 6.4 for grill-eligible findings |
| rfc-finder | Yes | Yes | No (excluded) | Find and link to IETF RFCs and related drafts |
| spec-compliance | Yes | Yes | No (excluded) | Check code against RFC/W3C/WHATWG requirements |
| show-me | Yes | Yes | Yes | Judgment-only skill for choosing when a visual (pseudocode, call tree, component tree, file tree, mermaid diagram, diff, HTML artifact) beats prose in an explanation; no subagents, tool calls, or scripts; also triggers on review findings, gauntlet convergence and conduct phase progress |
| update-docs | Yes | Yes | Yes | Audit and update stale docs against branch diffs; also offers to promote a plan's cross-file decisions into `docs/decisions/`, one record at a time and only on your approval |
| conduct | Yes | Yes | Yes | Walk a reviewed dev plan phase by phase via harness-native clean-context subagents; a healthy finish points at `/update-docs` (text only, never started for you) |
| plan-view | Yes | Yes | No (excluded) | Generate HTML dashboard and per-plan drill-down pages from a markdown dev-plan corpus; renders Mermaid fences as live diagrams via the Mermaid CDN runtime; `--rich` mode produces LLM-rendered per-plan views constrained by a widget toolkit; deterministic and rich pages are cross-linked bidirectionally (forward links emitted unconditionally, back-links injected by `relink_rich_pages()` on every plain run) |
| review-gauntlet | Yes | Yes (partial) | Yes (partial) | Chain the review gates (adversarial review, deep-review, security-review) into one convergence loop, with fixes applied by an isolated clean-context fixer subagent; opt-in per dev plan via `**Review Gates:** none \| full` on Claude (`none \| quick \| full` on Codex — see below), auto-chained from `conduct` and `fan-out`. Fixers must design the whole contract first (Guardrail 8), a seam-tripwire forces a redesign when fixes keep landing on the same seam, and in-contract decisions are logged as design deltas in the dev plan (or a `.gauntlet/` sidecar). Before reconcile it sets aside `Decision candidate:` advice (exact prefix, Minor, Documentation), prints it once and keeps it out of the fixer batch and convergence counts. `--resume`/`--fresh` pick an interrupted run back up from a target-keyed `.gauntlet/` ledger instead of restarting the gate corpus; auto-chained invocations are self-resuming with no extra flags. `/code-review` is not a gate on the Claude side (the harness blocks Claude from self-invoking it) — run `/code-review xhigh --fix` yourself; the Claude-side marker has no `quick` value as a result. On Codex, `/code-review` remains a native gate (unaffected) and `quick` still runs it alone; `security-review` is `deferred` (no primitive exists), and `deep-review` is gated pending nested-spawn confirmation — Codex `full` mode reports these slots explicitly rather than claiming they ran. `--report` writes an opt-in throwaway HTML report of the run (Claude and Codex, not Pi) |
| release | Yes (user-invoked only) | Yes (model-invocable; no documented opt-out found; explicit pre-mutation confirmation) | Yes (dry-run/audit) | Cut or re-sync a GitHub release from a `CHANGELOG.md` section in a canonical title+body shape (title `<repo> vX.Y.Z — <highlight>`, body = an optional `## What's New` summary paragraph + the section content with its header stripped — or a shorter compact digest of it, which a re-sync preserves when it is a valid body — + a `**Full diff:**` compare link), or in a target repo's own declared shape via a committed `.release-template.json` (title format, compare-line label, excluded sections, What's New presence — absence is a byte-for-byte no-op); an ordinary re-sync preserves the existing highlight and `## What's New` presence/content when recoverable (a recovered summary that embeds a CHANGELOG version header or an excluded heading is redrafted, not reused), making repeated re-syncs byte-identical unless the user overrides them or malformed existing content requires repair. `/release audit` scans tags, GitHub releases, and CHANGELOG versions for missing artifacts, releases whose remote tag was deleted, or drifted title/body (template-aware when a template applies), then reports a punch list before fixing anything; for a repo with no template, it also proposes (prints, never writes) a `.release-template.json` draft when the highest 3 qualifying releases agree on a stable shape that diverges from canonical (`no-template-convention-detected`); `/release audit --infer-template` runs that inference standalone (A1 → A2 → A2.5, proposal only) on templated and untemplated repos alike |
| in-your-own-words | Yes (user-invoked only) | Yes (explicit `$in-your-own-words` only; implicit invocation suppressed by `agents/openai.yaml`) | No (excluded) | Alignment gate: restates your steering input (chat, screenshots, links) as Sources read / Goal / Problem / Ask / Guesses / Gaps, then hard-stops until you explicitly confirm; persists nothing and takes no action; intended as an optional step before `grill` or `review-plan` |

Invoke each skill as `skein:<name>` (e.g. `skein:dev-plan`, `skein:review-plan`). `in-your-own-words` is user-invoked only: type `/skein:in-your-own-words` in Claude Code or `$in-your-own-words` in Codex. The namespaced form is the supported spelling; another plugin or skill source shipping the same bare name (`in-your-own-words`) may collide with it, and no uniqueness is claimed for the bare name. On Codex, implicit invocation is suppressed by the sidecar `plugins/skein-codex/skills/in-your-own-words/agents/openai.yaml` (`policy.allow_implicit_invocation: false`), verified on codex-cli 0.169.0; a Codex CLI that does not read the sidecar would leave the skill model-invocable. Judgment lenses ("high-reasoning" above) vs. mechanical/factual work follow the two-tier model/effort policy in [AGENTS.md](AGENTS.md#modeleffort-policy-target-policy-not-yet-fully-enforced).

Codex `conduct` and `review-gauntlet` require `spawn_agent` and `wait_agent`. Fresh phase workers and fixer batches use `fork_turns="none"` and their Codex dispatch templates; conductors consume delivered final reports and terminal status. Unsupported downstream review gates retain their explicit capability outcomes. Native gauntlet gates review pinned private snapshots, reject escaping/cyclic symlinks and source drift before fixes or ledger accounting, and emit a locally validated strict envelope. The native gate uses Codex 0.160.1’s app-server raw final answer to retain its explicit verdict; unsupported runtimes fail closed.

Codex `release` ships a read-only executable preflight adapter for macOS runtimes with a verified native process launcher. Direct argv and a closed child environment prevent ambient shell startup; the fixed system-interpreter bootstrap trusts the runtime, installed plugin and operating system. Canonical Homebrew Cellar tools may traverse root/current-user-owned directories writable by the system `admin` group; executable files and world-writable paths remain restricted, and pinned identities are reverified before application-tool launches. Claude launches the editorial checker through pinned `env -i` so Bash starts with an empty environment. No directory permissions need to be changed.

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

The marketplace name `skein` matches the entries in `.claude-plugin/marketplace.json` (Claude) and `.agents/plugins/marketplace.json` (Codex). To pick up upstream changes on Claude, re-add the marketplace and re-run `/plugin install skein@skein`. For an existing Codex Git marketplace, refresh its configured snapshot and then reinstall:

```bash
codex plugin marketplace upgrade skein
codex plugin add skein@skein
```

`marketplace add` registers the marketplace; repeating it for an existing Codex marketplace does not refresh the snapshot. `marketplace upgrade` follows the configured ref and does not reinstall the plugin. For a local-path install, `git pull` your clone and re-run the harness's plugin install command. There is no background sync step.

**Pinning to an existing release.** Prefer pinning over tracking `main`: pass `--ref vX.Y.Z` to `codex plugin marketplace add` (Codex), or resolve to a tag when adding the marketplace on Claude Code. See the release badge above or [the GitHub releases page](https://github.com/vr000m/skein/releases) for the current tag list. Tracking `main` follows unreleased commits.

If you are developing against a local clone instead, swap the marketplace source for a path: `/plugin marketplace add /path/to/skein` (Claude) or `codex plugin marketplace add /path/to/skein` (Codex).

If you are migrating from the older flat layout (skills installed directly under `~/.claude/skills/` and `~/.codex/skills/`), use `scripts/delete-skills.sh` to remove the immutable 11-skill migration-era set after verifying the plugin install loads correctly. It deliberately preserves the post-migration `grill`, `release`, and `review-gauntlet` directories. The cleanup regression test is `uvx pytest tests/parity/test_delete_skills.py -q`.

## Pi package

The repository also contains a Pi package at the root `package.json`. Install a
local checkout with `pi install /absolute/path/to/skein`, or install a pinned
Git revision with `pi install git:github.com/vr000m/skein@COMMIT_SHA`. Pi skills
use `/skill:skein-<name>` and are explicitly allowlisted; they do not provide
the Claude/Codex `skein:` namespace.

The Pi package currently exposes `show-me`, `content-draft`, `content-review`,
`update-docs`, `dev-plan`, `grill`, `deep-review`, `review-plan`,
`review-gauntlet`, `conduct`, and `release`. `fan-out`, `plan-view`,
`rfc-finder`, `spec-compliance`, and `in-your-own-words` (Pi port tracked in `docs/BACKLOG.md`) remain undiscoverable.
Worker-backed routes currently support only the verified operator-approved
`openai-completions` API-key, text-only, no-tools lane. The plain-prose review rule, the `--report` HTML report and the widened `show-me` review triggers are not ported to Pi (tracked in `docs/BACKLOG.md`). Unsupported providers,
OAuth credentials, and unavailable review gates fail visibly rather than being
silently substituted or counted as passes.

## Releases

skein follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html); changes are recorded in [`CHANGELOG.md`](CHANGELOG.md) in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

Tagged releases are published on the [GitHub releases page](https://github.com/vr000m/skein/releases) — see the release badge at the top of this file for the current tag. Pin an install to a specific tag with `--ref vX.Y.Z` instead of `--ref main` if you want a stable version rather than tracking `main`.

After merging a release-bearing PR and updating local `main`, use `skein:release` (`/release X.Y.Z` on Claude) to create or re-sync the tag and GitHub release. The skill previews the exact target, title, and body for confirmation before mutating remote state; do not hand-compose the old `git tag` + `gh release create` sequence.

Claude and Codex also run a non-blocking editorial preflight over the exact composed body. Bodies above 3,000 Unicode characters or top-level bullet records above 700 characters are flagged for review before confirmation; the operator can still accept the exact payload. Pi presents the same thresholds as guidance without claiming measured counts. Keep implementation-level detail in `CHANGELOG.md`, while the public release body stays scannable.

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
just check-decisions             # validate docs/decisions records (headers, status, supersession links, Applies to globs); part of just ci
just parity-tests                # bundle + allowlist + orchestration-contract + no-fallback + marker + managed-skill/cleanup-boundary regression coverage
just reconciliation-tests        # reconciliation parity + fixture + renderer + determinism
just pi-tests                    # Pi mirror suites (tests/pi)
just comment-count               # added comment lines on this branch vs main (heuristic record, not a gate)
just bundle-appliers             # regenerate bundled auto-fix pipeline inside each skill
```

## Layout

```
plugins/skein/skills/<name>/         Claude skills (SKILL.md per skill)
plugins/skein-codex/skills/<name>/   Codex skills (mirrored structure; per-harness dispatch idiom)
.claude-plugin/marketplace.json      Claude marketplace entry for skein
.agents/plugins/marketplace.json     Codex marketplace entry for skein
scripts/                             Canonical shell scripts (bundle/check/reconcile/parity/render/auto-fix)
docs/decisions/                      Decision records promoted from dev plans (format in its README; validated by `just check-decisions`)
site/                                skein.sh static site (Cloudflare Workers assets; `just site-preview`, `just site-deploy`)
```

See [AGENTS.md](AGENTS.md) for commands, architecture, authority model, contributor workflow, and the model/effort policy.
