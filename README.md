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
| review-plan | Yes | Yes | Audit a dev plan via five parallel fresh-context lenses (architecture, sequencing, spec-and-testing, assumptions, codebase-claims; four high-reasoning + one factual) before implementation; the architecture lens also audits negative-space topology gaps; reconciles findings by structural signature. A default-on triage-and-clarify loop records decisions into the plan before the marker is written (`--batch` skips it for CI). Opt-in `--auto-fix=trivial` applies allowlisted prose edits outside the immutable contract sections |
| rfc-finder | Yes | Yes | Find and link to IETF RFCs and related drafts |
| spec-compliance | Yes | Yes | Check code against RFC/W3C/WHATWG requirements |
| update-docs | Yes | Yes | Audit and update stale docs against branch diffs |
| conduct | Yes | Yes | Walk a reviewed dev plan phase by phase via harness-native clean-context subagents |
| plan-view | Yes | Yes | Generate HTML dashboard and per-plan drill-down pages from a markdown dev-plan corpus; renders Mermaid fences as live diagrams via the Mermaid CDN runtime; `--rich` mode produces LLM-rendered per-plan views constrained by a widget toolkit; deterministic and rich pages are cross-linked bidirectionally (forward links emitted unconditionally, back-links injected by `relink_rich_pages()` on every plain run) |

Invoke each skill as `skein:<name>` (e.g. `skein:dev-plan`, `skein:review-plan`).

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

**Pinning to a release.** Once tagged releases exist (the first will be `v0.1.0`, cut after this install switch merges), prefer pinning over tracking `main`: pass `--ref v0.1.0` to `codex plugin marketplace add`, and check tagged releases on [the GitHub releases page](https://github.com/vr000m/skein/releases) for Claude Code (which resolves the marketplace at add time). Tracking `main` follows unreleased commits.

If you are developing against a local clone instead, swap the marketplace source for a path: `/plugin marketplace add /path/to/skein` (Claude) or `codex plugin marketplace add /path/to/skein` (Codex).

If you are migrating from the older flat layout (skills installed directly under `~/.claude/skills/` and `~/.codex/skills/`), use `scripts/delete-skills.sh` to remove the pre-plugin copies after verifying the plugin install loads correctly.

## Releases

skein follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html); changes are recorded in [`CHANGELOG.md`](CHANGELOG.md) in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

The first tagged release will be **v0.1.0**, cut from `main` immediately after the public-GitHub install switch merges. Until then, all install instructions above resolve against `main`. Tagged releases are published on the [GitHub releases page](https://github.com/vr000m/skein/releases).

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
just parity-tests                # bundle + allowlist + orchestration-contract + no-fallback + marker parity (conduct + canonical anchor + review-plan marker write)
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

See [AGENTS.md](AGENTS.md) for commands, architecture, authority model, and contributor workflow.
