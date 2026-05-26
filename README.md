# skein

Namespaced skill plugin for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [OpenAI Codex CLI](https://github.com/openai/codex) agents. All skills load under the `skein:` namespace (`skein:dev-plan`, `skein:plan-view`, etc.) to avoid collisions with third-party skills.

## Skills

| Skill | Claude | Codex | Description |
|-------|--------|-------|-------------|
| dev-plan | Yes | Yes | Generate and manage development plans; `create` runs one fresh-context Explore subagent that gathers verified paths, patterns, dependency versions, and git refs before drafting |
| fan-out | Yes | Yes | Parallel agent orchestration via worktrees |
| content-draft | Yes | Yes | Draft content following style guidelines |
| content-review | Yes | Yes | Review content against style guidelines |
| deep-review | Yes | Yes | Multi-lens code review with fresh-context subagents; reconciles findings by structural signature. Opt-in `--auto-fix=trivial` applies a hard-coded allowlist of mechanical fixes (requires `--test-cmd`) |
| review-plan | Yes | Yes | Audit a dev plan via four parallel fresh-context lenses (architecture, sequencing, spec-and-testing, codebase-claims) before implementation; reconciles findings by structural signature. Opt-in `--auto-fix=trivial` applies allowlisted prose edits outside the immutable contract sections |
| rfc-finder | Yes | Yes | Find and link to IETF RFCs and related drafts |
| spec-compliance | Yes | Yes | Check code against RFC/W3C/WHATWG requirements |
| update-docs | Yes | Yes | Audit and update stale docs against branch diffs |
| conduct | Yes | Yes | Walk a reviewed dev plan phase by phase via harness-native clean-context subagents |
| plan-view | Yes | Yes | Generate HTML dashboard and per-plan drill-down pages from a markdown dev-plan corpus; `--rich` mode produces LLM-rendered per-plan views constrained by a widget toolkit; deterministic and rich pages are cross-linked bidirectionally (forward links emitted unconditionally, back-links injected by `relink_rich_pages()` on every plain run) |

Invoke each skill as `skein:<name>` (e.g. `skein:dev-plan`, `skein:review-plan`).

## Plugin install

Install through the harness plugin CLI on each machine. There are no rsync, promote, or bootstrap scripts — the marketplace files in this repo are the install surface.

**Claude Code:**

```bash
# from a clone of this repo, point Claude at the local marketplace
/plugin marketplace add /path/to/skein
/plugin install skein@skein-local
```

**Codex CLI:**

```bash
codex plugin marketplace add /path/to/skein
codex plugin add skein@skein-local
```

The marketplace name `skein-local` matches the entries in `.claude-plugin/marketplace.json` (Claude) and `.agents/plugins/marketplace.json` (Codex). When you edit skills in this repo, re-run `/plugin install skein@skein-local` or `codex plugin add skein@skein-local` on the relevant harness to pick up the changes — there is no separate sync step.

If you are migrating from the older flat layout (skills installed directly under `~/.claude/skills/` and `~/.codex/skills/`), use `scripts/delete-skills.sh` to remove the pre-plugin copies after verifying the plugin install loads correctly.

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
just parity-tests                # bundle + allowlist + orchestration-contract + no-fallback parity
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
