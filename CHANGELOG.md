# Changelog

All notable changes to skein are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); skein adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Two-tier model/effort policy across all Skein skills.** Every subagent spawn now names its own tier rather than inheriting the parent session's: judgment work (review/planning) → strongest model at high effort; mechanical work (implementation/testing) → cheaper model at lower effort; factual lookups → cheapest tier. Documented in `AGENTS.md` (Model/Effort Policy) with a README pointer. Claude uses `model:`+`effort:` on the `Agent` call; the Codex mirror uses `reasoning_effort=high|medium|low` prose hints (idiom-divergent by sanctioned convention, not drift).
- **`tests/parity/test-spawn-tiers.sh`** — a new cross-skill tier census that walks both `plugins/skein/skills/*/SKILL.md` and `plugins/skein-codex/skills/*/SKILL.md`, asserting per-spawn/per-lens expected tier counts and a pinned total of opus/high (Claude) / reasoning_effort=high (Codex) spawns each carrying a why-comment. Falsifiable and wired into `just parity-tests`.
- **`/fan-out` worker `--effort` support.** `fan-out.sh` gains an `--effort` flag and `FANOUT_EFFORT` env (Codex mirror: `FANOUT_EFFORT` + `FANOUT_EXTRA_ARGS` pass-through), threaded into the `claude -p` / `codex exec` worker launch.
- **R6 fan-out clean-context test-writer contract** — `fan-out/test-writer-prompt.md`, a Writer-designated Integration-Seams contract injection, an anti-cheat "contract wins" rule in `agent-prompt.md`, and a deterministic seeded-divergence fixture + `run-seeded-divergence.sh` runner (both trees). The separate-subagent spawn topology ships documented but gated on unconfirmed nested-spawn runtime support (see `docs/dev_plans/CODEX_MIRROR_BACKLOG.md`).

### Changed
- **`/deep-review` architecture lens is now the strong review tier** — `model: opus, effort: high` (Claude) / `reasoning_effort=high` (Codex), up from the previous cheaper diff-level tier, so all code-review lenses except the factual documentation lookup run at the review tier.
- **`/fan-out` default worker tier is `--model sonnet --effort medium`** (was `opus`); `--model opus` opt-up documented for hard tasks.
- **`check-prompt-parity` normalizes R6 idiom divergence** in `fan-out/agent-prompt.md` + `test-writer-prompt.md`, excising the harness-idiom spans while still byte-guarding the remainder.

## [0.2.4] - 2026-06-21

### Added
- **Mermaid diagrams render live in `/plan-view` HTML.** `render_markdown` now emits `<pre class="mermaid">` for ` ```mermaid ` fences (HTML-escaped, `<pre>` chosen so the raw diagram source stays readable as fallback), and both `template.html` / `plan-template.html` load the Mermaid v11 ESM runtime from jsDelivr (`mermaid@11`, `startOnLoad: true`, `securityLevel: 'strict'`). CDN-only by design (no vendoring); diagrams need a network fetch to render. Applied identically to the skein-codex mirror.
- **Conditional `## Architecture & Call Flow` section in the dev-plan template.** Included only when a plan has 2+ independently-executing components: a component graph (Mermaid), a trigger-order `sequenceDiagram`, and a context-lifecycle table. `dev-plan` SKILL.md documents the inclusion heuristic, a pre-phase user-confirmation gate, the three sub-elements, placement (after Integration Seams, before Testing Notes), and that the section is above the review marker (immutable contract).
- **Negative-space topology audit in the `/review-plan` architecture lens.** The lens now reconstructs the implied call-flow from Files-to-Modify + Technical Specifications and flags components/triggers/context-transitions a plan needs but never names, plus a topology-omission backstop (Missing Task / Important when 2+ components lack an `## Architecture & Call Flow` section).
- **Interactive triage-and-clarify elicitation loop in `/review-plan`** (default-on Step 6.4): triage via free-form selection over unbounded findings, per-finding clarify options, then route — act-on decisions to `/dev-plan update` (above the marker), waived findings to a `### Review Waivers` subheading (below the marker). New `--batch` flag skips the loop for unattended/CI runs and is orthogonal to `--auto-fix=trivial`. A write-then-hash ordering invariant pins: loop edits flush → auto-fix → marker hashed exactly once.
- Model / thinking-level routing table in the skills-architecture design doc (per skill → lens → Claude model+effort → Codex reasoning level) with a maintenance note.

### Changed
- Bumped both plugin manifests to `0.2.4` in lockstep (the `version` field is the update cache key; both mirrors must move together).
- `## Architecture & Call Flow` added to `AF_FORBIDDEN_HEADINGS` (canonical `scripts/lib/auto-fix-common.sh`, re-bundled to all skill subtrees) and to both `review-plan` prose forbid lists, so `--auto-fix=trivial` cannot rewrite the new immutable section.

## [0.2.3] - 2026-06-15

### Fixed
- `/review-plan` now writes its review marker via a bundled deterministic entrypoint (`scripts/write-review-marker.py`) instead of an LLM hand-following a prose recipe at Step 7. **Root cause (confirmed from session transcripts, both `/review-plan` and `/conduct` on 0.2.2):** the 0.2.2 fix hardened `conduct/marker.py` (code) and both SKILL.md mirrors (prose), but `/review-plan` still computed the marker hash by hand — and an agent, despite the byte-faithful prose in context, wrote `above = b'\n'.join(lines[:idx])`, which drops the newline immediately above the marker (`join` separates, it does not terminate). That rstripped hash diverged from `conduct`'s byte-faithful slice (`plan_text[:span_start]`), so `/conduct` false-flagged a freshly reviewed plan as drifted. Prose cannot prevent the `splitlines`/`join` newline-eating trap; only shared deterministic code can.
- The marker hash is now computed by the same `marker.py` authority `/conduct` validates with — promoted to a canonical `scripts/marker.py` and fanned into both `review-plan` mirrors by `scripts/bundle-appliers.sh` (per-skill extras via `bundle_extra_for`). All copies (conduct ×2, review-plan ×2) are anchored byte-identical to the canonical file by `tests/parity/test-marker-parity.sh`, so the two skills can no longer disagree on a plan's hash.
- `/review-plan` Step 7 adopts the auto-fix applier's abort-if-absent / never-hand-compute contract, and now **aborts** (rather than appending the marker at EOF) when a plan has no marker line and no template placeholder divider — burying the marker below the workspace would fold the workspace into the hashed contract.

### Changed
- Bundle map (`scripts/lib/bundle-map.sh`) grows a per-skill extras hook (`bundle_extra_for`) so `marker.py` + `write-review-marker.py` ship into `review-plan` only (not `deep-review`), preserving the "bundled == operative" invariant. `check-sync.sh` and `tests/parity/test-applier-bundle-parity.sh` enumerate the extras so their byte-identity is guarded.
- Added `tests/parity/test-marker-parity.sh` (anchored byte-identity + post-write round-trip + the named `9fa0989`-vs-`df8d891` divergence regression) and `tests/auto-fix/test-review-plan-marker-write.sh` (recipe-removed negative assertion across both mirrors, abort contract, placeholder happy path).

## [0.2.2] - 2026-06-12

### Fixed
- Quoted SKILL.md frontmatter values that contain multiple bracketed argument tokens or colon-bearing prose so Codex can load all bundled `skein:*` skills without YAML parse warnings.
- `/conduct` review-marker hashing (`conduct/marker.py`) is now byte-faithful, matching the documented recipe (`git hash-object` of the bytes above the marker line). `strip_marker_for_hashing` previously popped the blank line that normally precedes the marker and round-tripped through `splitlines()`/`join()`, silently normalizing CRLF→LF; `compute_plan_hash` also read via `read_text`, translating line endings before hashing. Together these made the computed hash disagree with `git hash-object` of the above-marker bytes whenever a plan had a blank line before its marker (the common markdown style) or used CRLF endings — so preflight false-flagged a valid plan as stale (hard-stopping a first run, or, on `--resume`, rewriting the marker into a form no byte-faithful external checker accepts). Hashing now slices the plan at the marker line's exact byte offset with line endings preserved. **Migration:** markers written by `/review-plan` with a blank line before them now validate correctly; any marker previously written by the old `marker.py` blank-popping path on such a plan reports stale once and refreshes on the next `/review-plan` or `--resume`.

- `write_marker` now hashes the exact bytes it writes above the marker. It previously hashed the contract *before* appending the trailing newline that separates the contract from the marker line, so marking a plan that had no trailing newline (e.g. a freshly authored plan) recorded a hash of bytes that were never written above the marker — leaving the plan stale the instant `/review-plan` marked it, and `/conduct` would then reject a plan the user had just reviewed. (Pre-existing; surfaced by adversarial review.)
- `write_marker` reads and writes plan bytes directly (`read_bytes`/`write_bytes`) instead of text-mode `read_text`/`write_text`. Text mode applies universal-newline translation whose direction is platform-dependent — on Windows `write_text` re-expands `\n` to `\r\n` on disk — so the bytes `write_marker` hashed could differ from the bytes `compute_plan_hash` (byte-faithful since this release) reads back, marking a CRLF plan stale on Windows the instant it was written. Reading and writing raw bytes keeps both sides on identical bytes on every platform and preserves a plan's existing line endings.

### Changed
- Hardened the review-marker locators: `last_marker_index` (line index) and `_marker_line_span` (byte offset) now share one `_scan_marker_lines` fence-tracking core so they can never drift to different markers on the same plan. Documented the byte-faithful invariant in `conduct` and `review-plan` SKILL.md (both mirrors) to prevent re-introducing line-ending/blank-line normalization. Added `tests/parity/test-conduct-marker-parity.sh` (wired into `just parity-tests`) asserting `conduct/marker.py` stays byte-identical across the skein and skein-codex mirrors.

## [0.2.1] - 2026-06-12

### Documentation
- Clarified in both `deep-review` SKILL.md copies that `scripts/render-reconciled-report.sh` is a repo-only reference renderer, deliberately **not** bundled into the installed skill (per `scripts/lib/bundle-map.sh`) — the running review renders by hand from the report template, so the renderer's absence under the installed `scripts/` is expected, not a broken bundle. Prevents review runs from false-flagging it as a missing artifact.

## [0.2.0] - 2026-06-03

### Added
- Fifth `assumptions` lens (Opus) for `/review-plan`: audits claims the plan states as settled fact but cannot verify from the codebase — backend/external behaviour, business semantics, data shape, unread contracts, environmental facts. `/review-plan` now runs four high-reasoning Opus lenses plus one Haiku factual lens.

### Fixed
- Cross-lens reconciliation (`scripts/reconcile-findings.sh`) no longer collapses unanchored findings. Findings with no location anchor (empty `file` + `-1` line) each receive a unique merge signature instead of sharing one `("", -1, category)` signature and silently dropping all but one. Anchored merge/related behaviour is byte-for-byte unchanged; both the `jq` and awk-fallback parsers partition identically (including an explicit `line:-1`). Also benefits `/deep-review`, which shares the engine.

## [0.1.0] - 2026-05-30

First public release.

### Added
- Eleven namespaced skills under `skein:*` shipped as a single plugin for Claude Code and OpenAI Codex CLI: `dev-plan`, `review-plan`, `conduct`, `fan-out`, `deep-review`, `content-draft`, `content-review`, `rfc-finder`, `spec-compliance`, `update-docs`, `plan-view`.
- Dual-harness plugin layout: `plugins/skein/` (Claude mirror) and `plugins/skein-codex/` (Codex mirror) with intentional dispatch-idiom and path-anchor divergence (`${CLAUDE_PLUGIN_ROOT}` template substitution vs `$SKILL_DIR` env-export).
- Opt-in `--auto-fix=trivial` tier for `/deep-review` and `/review-plan`, gated by a single-source allowlist (`scripts/auto-fix-allowlist.json`) and bundled appliers (regenerated by `just bundle-appliers`).
- Repo invariants: canonical-↔-bundled byte-identity check, Claude-↔-Codex SKILL.md prompt parity check, trunk-snippet parity check, no-manual-apply-fallback enforcement.
- `scripts/delete-skills.sh` to surgically remove pre-plugin flat skill copies after a successful plugin install.
- Public GitHub install: both harnesses install directly from `vr000m/skein` without a local clone; local-clone form retained as a contributor workflow.

### Changed
- Marketplace renamed from `skein-local` to `skein` in both `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`. Install command is `/plugin install skein@skein` (Claude) and `codex plugin add skein@skein` (Codex).

[Unreleased]: https://github.com/vr000m/skein/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/vr000m/skein/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/vr000m/skein/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/vr000m/skein/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/vr000m/skein/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/vr000m/skein/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/vr000m/skein/releases/tag/v0.1.0
