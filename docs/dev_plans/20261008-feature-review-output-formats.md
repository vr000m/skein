# Task: Review-output formats (plain prose, HTML report, show-me triggers)

**Status**: Not Started
**Component**: review-skills
**Assigned to**: Claude (Codex mirror via codex:rescue)
**Priority**: Medium
**Branch**: feature/karpathy-output-formats
**Created**: 2026-10-08
**Review Gates**: full

## Objective

Make review output faster to read and trust: a plain-prose writing rule for review findings, an opt-in throwaway HTML report (`--report`) for gauntlet and deep-review runs, and wider `show-me` triggers.

## Context

Source: Karpathy's thread (https://x.com/karpathy/status/2105819303471976479), as the author reads it. His point, as paraphrased here: as LLMs do more work, the human job is oversight and understanding. Pick output formats that ease that: controlled-language prose (ASD-STE100 as inspiration), diagrams, HTML pages, throwaway artifacts. This is motivation only; nothing below depends on the thread's exact wording. Explainer video is out of scope (`docs/explainer-video-idea.md`).

Today no review skill has a writing-style rule. `show-me` has no review, gauntlet or conduct triggers. `plan-view` renders dev-plan corpora only, not findings.

Facts verified during plan review (2026-10-08, three rounds):
- The gauntlet ledger (`lib/convergence-ledger.sh`) stores counts and key lists only (no finding text, no severity). Its file is `.gauntlet/ledger-<author>-<slug>-<digest12>.json` (`gauntlet-common.sh:135`), so it is per target and per harness author. Per-round files (`<gate>.envelope.json`, `*.normalized.jsonl`, `findings.jsonl`, `reconciled.json`, `present-keys.txt`) are already written to `$run_dir/round-N` (`review-gauntlet/SKILL.md:101-110,240-250`), but `$run_dir` itself is not defined in any skill file.
- deep-review never persists a reconciled envelope; reconcile output is consumed inline (`deep-review/SKILL.md:636-639`). All `.deep-review/` state writes go through `persist-deep-review-state.sh` (`SKILL.md:35,730`). Shell state does not survive Bash tool calls (`deep-review/SKILL.md:179`).
- The deep-review schema-versioning bullet (`deep-review/SKILL.md:606`) sits inside the `GENERIC FINDING SCHEMA AND MERGE` block (`:595-623`). `scripts/check-prompt-parity.sh:653-657` holds that block byte-identical across deep-review and review-plan in both mirrors.
- `scripts/check-sync.sh` treats each skill's `scripts/` dir as a byte-mirrored bundle of canonical repo-root `scripts/`, declared in `scripts/lib/bundle-map.sh`. It checks only skein and skein-codex (`check-sync.sh:59-61`). `tests/parity/test-applier-bundle-parity.sh:300` checks "bundled == operative" for `.sh` references only.
- `scripts/bundle-appliers.sh:21` lists `plugins/skein-pi` in MIRRORS and stages once per skill, then `rsync --delete`s into every mirror (`:49-72`). Pi gets deep-review and review-plan bundles unless a per-file exclusion is added.
- A third mirror exists: `plugins/skein-pi/skills/{review-gauntlet,deep-review,review-plan,show-me}` (Pi-native rewrites; `tests/pi/test_skill_inventory.py:90-99` pins Pi show-me frontmatter).
- `scripts/finding-key.sh` builds the regression key from (file, category, normalized summary).
- The gate-1 (Codex adversarial) prompt is not a file template in either mirror. Claude: the orchestrator composes it from prose around a `"<adversarial-review prompt>"` placeholder (`review-gauntlet/SKILL.md:118-125`). Codex: it is an f-string in `plugins/skein-codex/skills/review-gauntlet/native_gates.py:576`. Gate 3 (`security-review`) is external.
- review-plan lens prompts call the finding summary field `finding` before serialization (`review-plan/SKILL.md:784`); deep-review calls it `summary`.
- `justfile` `parity-tests` and `gauntlet-tests` list tests by name, no glob. `lint-python` runs ruff over the whole repo; `lint-scripts` covers `tests/*/*.sh` and bundled shell.
- The installed plugin cache (`~/.claude/plugins/cache/skein/skein/`) is 0.8.5; the repo is 0.9.2. The auto-chained gauntlet runs the cached version until the next release refreshes it.
- `conduct` auto-chains `review-gauntlet --plan <plan>` with a fixed argument set (`conduct/SKILL.md:367`). The gauntlet invokes `skein:deep-review --verbose` at top level each round (`review-gauntlet/SKILL.md:89,129`).

## Requirements

- R1: Review prose follows a short plain-prose rule (short sentences, one meaning per word, active voice, no filler). It applies to `evidence`, `suggestion` and overall summaries. The gate-1 adversarial prompt gets the rule as one plain sentence. It must NOT touch the finding summary line (`summary` in deep-review, `finding` in review-plan lens prompts; it feeds `finding-key.sh`), schemas, severity labels, or any machine-read field. Gate 3 (`security-review`) is out of scope: skein does not author it.
- R2: A gauntlet or deep-review run with `--report` emits one self-contained HTML report: findings by severity, round-by-round convergence, diff scope. Opt-in; default output is unchanged. A failing report never changes a run's outcome.
- R3: `show-me` triggers cover review findings, gauntlet convergence, and conduct phase progress, still defer to `plan-view` for plans, and point review findings and gauntlet convergence at the `--report` flag of the review skills (by skill and flag, not by state path).
- Claude and Codex mirrors stay aligned; path anchors (`${CLAUDE_PLUGIN_ROOT}` vs `$SKILL_DIR`) are never collapsed.
- `plugins/skein-pi` is out of scope for R1, R2 and R3, and must receive no copy of the new scripts.
- `just ci` passes.

## Review Focus

- R1 must not alter text that tests or parsers pin (compact/full finding rendering at `deep-review/SKILL.md:761`, `review-plan/SKILL.md:784`) or any input to `finding-key.sh`. R1 blocks must sit outside the `GENERIC FINDING SCHEMA AND MERGE` block and outside lens output-schema fences.
- Bundle invariant: a script ships into a skill iff that skill's SKILL.md invokes it (`scripts/lib/bundle-map.sh`, `scripts/check-sync.sh`), and Pi receives none of it.
- HTML must be a single file with no external fetches; finding text is untrusted and must be escaped in text nodes and attributes. Output containment: the orchestrator guards the report path with the tree owner's guard first; the renderer re-checks as defence in depth.
- Mirror parity guards: `scripts/check-sync.sh`, `scripts/check-prompt-parity.sh`, `tests/parity/*`.
- State-write discipline: `.deep-review/` state files are written only by `persist-deep-review-state.sh`; `.gauntlet/` state by the existing guarded writers. The report file (`report-*.html`, `*.report.html`) is the one sanctioned exception: it is written only by `render-report.py`, only after the tree owner's guard has checked its path, and it is never read back as state.

## Implementation Checklist

### Phase 1: Plain-prose rule (R1)

**Impl files:** `plugins/skein/skills/review-gauntlet/SKILL.md, plugins/skein/skills/deep-review/SKILL.md, plugins/skein/skills/review-plan/SKILL.md, plugins/skein-codex/skills/review-gauntlet/SKILL.md, plugins/skein-codex/skills/review-gauntlet/native_gates.py, plugins/skein-codex/skills/deep-review/SKILL.md, plugins/skein-codex/skills/review-plan/SKILL.md`
**Test files:** `tests/parity/test-prose-rule-parity.sh, justfile`
**Test command:** `bash tests/parity/test-prose-rule-parity.sh && bash scripts/check-report-templates.sh && bash tests/gauntlet/test-gauntlet-skill-shape.sh && ./scripts/check-prompt-parity.sh`
**Goal:** The rule changes how prose is written only; no schema, label, pinned string, or `finding-key.sh` input changes.

- Write two named blocks, each between fixed anchor comment lines:
  - Block A (authoring rule): inserted into every lens prompt template in `deep-review` (5) and `review-plan` (5 lenses plus the Contradiction Pass = 6). Per mirror: 11 occurrences. `review-gauntlet` gets no Block A.
  - Block B (summary-prose rule): inserted at the orchestrator report step in all three skills. Per mirror: 3 occurrences.
- Gate-1 adversarial prompt: add one plain sentence stating the rule. Claude: in the `review-gauntlet/SKILL.md` prose that composes the prompt (around `:118-125`). Codex: the same sentence in the prompt string in `native_gates.py` (via `codex:rescue`). It is not a byte-identical anchored block; a string assert in the parity test checks it exists in both places.
- Both blocks state the rule as checkable items (sentence length cap, active voice, one term per concept, no filler), cite ASD-STE100 as inspiration only, and contain the sentence exempting the finding summary line. The sentence names both field names: "the finding summary line (`summary` in deep-review, `finding` in review-plan lens prompts)".
- Keep both blocks harness-neutral so each is byte-identical across mirrors; place them outside the lines pinned by `scripts/check-report-templates.sh`, outside the `GENERIC FINDING SCHEMA AND MERGE` block, and outside any lens output-schema fence.
- Check `native_gates.py` tests (`tests/` for the Codex native gate) for pinned prompt text before editing.
- Codex half first via `codex:rescue`, then align the Claude half in the same commit.
- Parity test: extract each block between its anchors and byte-compare all copies; assert exact occurrence counts per mirror; assert each block contains the exemption sentence; assert no anchor sits inside a schema fence or the GENERIC block; assert the gate-1 sentence in both mirrors.
- Wire the test into `justfile` `parity-tests` in the same commit.

### Phase 2: HTML report (R2)

**Impl files:** `scripts/render-report.py, scripts/report-hook.sh, scripts/lib/bundle-map.sh, scripts/bundle-appliers.sh, tests/parity/test-applier-bundle-parity.sh, plugins/skein/skills/review-gauntlet/scripts/render-report.py, plugins/skein/skills/review-gauntlet/scripts/report-hook.sh, plugins/skein-codex/skills/review-gauntlet/scripts/render-report.py, plugins/skein-codex/skills/review-gauntlet/scripts/report-hook.sh, plugins/skein/skills/deep-review/scripts/render-report.py, plugins/skein/skills/deep-review/scripts/report-hook.sh, plugins/skein-codex/skills/deep-review/scripts/render-report.py, plugins/skein-codex/skills/deep-review/scripts/report-hook.sh, plugins/skein/skills/review-gauntlet/SKILL.md, plugins/skein-codex/skills/review-gauntlet/SKILL.md, plugins/skein/skills/deep-review/SKILL.md, plugins/skein-codex/skills/deep-review/SKILL.md`
**Test files:** `tests/gauntlet/test-render-report.sh, tests/gauntlet/test-gauntlet-skill-shape.sh, tests/gauntlet/fixtures/render-report/, tests/parity/test-applier-bundle-parity.sh, justfile`
**Test command:** `bash tests/gauntlet/test-render-report.sh && bash tests/gauntlet/test-gauntlet-skill-shape.sh && just check-sync && just lint-python && ./scripts/check-prompt-parity.sh`
**Goal:** The renderer only reads files it is handed and writes one contained HTML file; it never calls git and never mutates ledger or state. The hook always returns 0, so a report failure never changes a run's decision.

Ordering inside the phase (each step must leave `just ci` green; assertions that need a later step land with that step):
1. Decision gate: read the existing round-loop writes (`review-gauntlet/SKILL.md:101-110,240-250`) and confirm the real field names of `reconciled.json` and the ledger, including the gate-1 shape (`lens: <gate>`, `confidence`, no `suggestion`, nullable `line`; `lib/run-gate.sh:215-223`). Also confirm the tree-owner guard names (`lib/state-path-guard.sh`; `af_assert_no_symlink` in `lib/auto-fix-common.sh`) are reachable from each skill's bundle. Record field names, guard names and the outcome in `## Findings` (below the marker).
2. Bundling: canonical `scripts/render-report.py` and `scripts/report-hook.sh`; a `BUNDLE_REPORT=(render-report.py report-hook.sh)` group in `scripts/lib/bundle-map.sh` expanded from both the review-gauntlet and deep-review arms; a per-file Pi exclusion in `scripts/bundle-appliers.sh` (name the mechanism: filter the staged tree before the Pi rsync); widen the `test-applier-bundle-parity.sh` §7 regex to `\.(sh|py)`; add a section asserting Pi's skill `scripts/` contain no `render-report.py` or `report-hook.sh` and equal canonical minus `BUNDLE_REPORT`; `just bundle-appliers`. Renderer, hook and bundle tests plus `justfile` wiring land in the same commit.
3. Gauntlet SKILL.md (both mirrors): define `$run_dir` as `.gauntlet/<ledger-stem>/` resolved through `lib/state-path-guard.sh`, where `<ledger-stem>` is the ledger file's basename without `.json` (so it is per target and per harness author); tie its lifecycle to the ledger (`--fresh` removes `$run_dir` with the ledger; `--resume` takes `round_n` from the ledger's `rounds` array); add the `--report` flag and argument-hint; add one named terminal-exit report step that every terminal exit routes through (the five terminal tokens at `:144-148`, the `--resume` exit-5 refusal at `:163`, and the auto-chain exit-5 report-back at `:81`), regenerated from full state on every terminal exit including `--resume`. State that gate 2 (`skein:deep-review --verbose`) never receives `--report`. Add the gauntlet `--report`-gating shape assertions to `tests/gauntlet/test-gauntlet-skill-shape.sh` in the same commit.
4. deep-review SKILL.md (both mirrors): add the `--report` flag and argument-hint, declared a rendering-mode modifier like `--verbose` (composable, changes no lens dispatch; update the argument-rule sentences at `:20-26` and assert them); add the report step that re-runs the audited reconcile in one Bash call, writes the audited envelope to a temp file in the scratch area (not under `.deep-review/`), and passes it by path. Add the schema-lockstep note for `render-report.py` outside the `GENERIC FINDING SCHEMA AND MERGE` block (beside the reconcile step near `:636-642`), in both mirrors. Add deep-review's `--report`-gating shape assertions in the same commit. Never before step 2.

Tasks:
- Renderer CLI: `render-report.py [--ledger <path>] [--round N=<envelope>]... [--envelope <path>] [--diff-stat <file>] --root <dir> --out <file>`. Gauntlet passes `--ledger` plus one `--round` per round; deep-review passes one `--envelope` and no `--ledger`. Envelopes are reconciler v2 (the audited output). The renderer asserts `schema_version == 2` on envelopes only and exits non-zero otherwise, like `scripts/render-reconciled-report.sh`; a ledger has no `schema_version` and is never version-checked. With a ledger and no `--round`, it renders a counts-only report and labels it. The renderer never re-implements dedup. Add it as a third lockstep point (see step 4).
- Diff scope: the orchestrator passes the hook explicit scope flags from its own resolved variables: `--base <ref> --head <ref>`, `--uncommitted`, or `--pr <N>`. The hook captures `git diff --stat` for that scope (uncommitted mode adds untracked files) to a file and passes `--diff-stat <file>`. The report labels the captured mode and capture time. An absent `--diff-stat` flag renders "diff scope unavailable" and exits 0. A given-but-unreadable path is a failure (non-zero).
- Severity buckets in this order: Critical, Important, Minor, then an "Other" bucket (after Minor) for any non-canonical severity.
- Escape all finding text for text nodes and attribute contexts; inline CSS only; no scripts, no external URLs.
- Containment, two layers. Orchestrator step: guard the report path with the tree owner before calling the hook (gauntlet: `lib/state-path-guard.sh`; deep-review: `af_assert_no_symlink`). Renderer: `--root` and `--out` arguments; refuse output outside the root, symlink components, and `..`; write via temp file and rename.
- Output paths: gauntlet `.gauntlet/<ledger-stem>.report.html` (per target, per harness author); deep-review `.deep-review/report-<harness>.html` (latest-run view per harness, like `latest-<harness>.json`).
- `report-hook.sh` takes the scope flags above, the envelope or ledger paths, and `--root`/`--out`; runs `command -v python3` (soft dependency; warn and skip when absent), runs `git check-ignore` on the output path and warns if it is not ignored, runs the renderer, logs any failure as a warning, and always exits 0.
- `--report` is not forwarded by `conduct`'s auto-chain; running with the report requires invoking the gauntlet directly.
- Existing tests this phase edits: `tests/parity/test-applier-bundle-parity.sh` (§7 regex, Pi section) and `tests/gauntlet/test-gauntlet-skill-shape.sh` (gating assertions).

### Phase 3: show-me triggers (R3)

**Impl files:** `plugins/skein/skills/show-me/SKILL.md, plugins/skein-codex/skills/show-me/SKILL.md, docs/BACKLOG.md`
**Test files:** `tests/parity/test-show-me-triggers.sh, justfile`
**Test command:** `bash tests/parity/test-show-me-triggers.sh`

- Add bullets under "When to reach for a visual" for review findings, gauntlet convergence, and conduct phase progress; update the frontmatter `description`.
- Wrap the new bullets in fixed anchor comment lines so they can be byte-compared across mirrors.
- Under "Composing with other skills", point review findings and gauntlet convergence at the `--report` flag of `review-gauntlet` and `deep-review` (skill and flag, not a path); keep conduct phase progress as a plain mermaid or table trigger; keep the "defer to plan-view" note.
- Preserve the sanctioned Claude/Codex divergence (the Mermaid and HTML-artifact bullets, currently lines 32-33); anchor on that content, not line numbers.
- New test asserts the three triggers and the `--report` pointer appear in both mirrors and byte-compares the anchored new bullets across mirrors; wire into `justfile` `parity-tests` in the same commit.
- Add the Pi follow-up entry to `docs/BACKLOG.md`.

## Technical Specifications

### Files to Modify
- The six review SKILL.md files (R1 blocks; R2 flag, hook step and argument-hints in gauntlet and deep-review, both mirrors; `$run_dir` definition and lifecycle in both gauntlet mirrors; schema lockstep note beside the reconcile step in both deep-review mirrors, outside the GENERIC block).
- `plugins/skein-codex/skills/review-gauntlet/native_gates.py` (gate-1 sentence).
- Both `show-me/SKILL.md` files (R3).
- `scripts/lib/bundle-map.sh` (`BUNDLE_REPORT` group), `scripts/bundle-appliers.sh` (per-file Pi exclusion), `tests/parity/test-applier-bundle-parity.sh` (§7 regex to `.sh|.py`, Pi section), `tests/gauntlet/test-gauntlet-skill-shape.sh` (gating assertions).
- `justfile` (add the three new tests to `parity-tests` and `gauntlet-tests`; unconditional).
- `docs/BACKLOG.md` (Pi follow-up).

### New Files to Create
- `scripts/render-report.py` and `scripts/report-hook.sh` (canonical) and, via `just bundle-appliers`, byte-identical copies under both mirrors for review-gauntlet and deep-review.
- `tests/parity/test-prose-rule-parity.sh`, `tests/parity/test-show-me-triggers.sh`, `tests/gauntlet/test-render-report.sh`, fixtures under `tests/gauntlet/fixtures/render-report/`.

### Architecture Decisions
- Renderer and hook are canonical in `scripts/`, bundled per the existing bundle map as one `BUNDLE_REPORT` group (not two `bundle_extra_for` arms), not hand-authored in mirrors: this is what `check-sync.sh` and `test-applier-bundle-parity.sh` enforce.
- Standalone renderer, not an extension of `plan-view/generate.py`: that file takes a plan corpus (`generate.py:1659-1710`), a different input shape.
- Renderer consumes the reconciler v2 envelope so dedup stays in one place (`reconcile-findings.sh`), and asserts `schema_version == 2` on envelopes.
- Renderer is pure: no git calls. The hook captures the diff stat and passes it as a file.
- The hook is a bundled script, not SKILL.md prose, so "never changes the decision" is testable as exit 0 plus a warning plus no writes outside the output path. It always returns 0.
- Decision (grilled, round 2): `render-report.py` is excluded from the Pi mirror in `bundle-appliers.sh` (and listed in Phase 2 impl files), keeping bundled==operative and honouring "Pi out of scope".
- Decision (grilled, round 3): the gate-1 prompt has no file template in either mirror. Block A is 11 per mirror (lens prompts only). Gate-1 gets one plain sentence, in the Claude SKILL.md prose and in the Codex prompt in `native_gates.py` (via `codex:rescue`), checked by a string assert. This replaces the round-2 decision that put Block A (12 occurrences) in the gate-1 prompt.
- Decision (grilled, round 3): containment is two layers. The orchestrator guards the report path with the tree owner (`lib/state-path-guard.sh` for gauntlet, `af_assert_no_symlink` for deep-review) before calling the hook; the renderer's `--root`/`--out` check stays as defence in depth. Review Focus names the report file as the one sanctioned write; a boundary test is added. This replaces the round-2 "renderer-only containment" rationale.
- Decision (grilled, round 3): deep-review passes the renderer the audited envelope by file path, the same input mode as the gauntlet. The orchestrator re-runs the audited reconcile in one Bash call and writes the envelope to a scratch temp file, not under `.deep-review/`. No stdin mode; no change to `persist-deep-review-state.sh`. This replaces the round-2 stdin decision.
- Decision (grilled, round 3): renderer CLI is `--ledger`, repeatable `--round N=<envelope>` and `--envelope`; the `schema_version` check applies to envelopes only; a ledger with no rounds renders a labelled counts-only report. `$run_dir`'s lifecycle follows the ledger: `--fresh` removes it, `--resume` derives `round_n` from the ledger's `rounds` array. The ledger and diff-stat get Integration Seams rows.
- Decision (grilled, round 2): `$run_dir` is defined as `.gauntlet/<ledger-stem>/` in both gauntlet mirrors, resolved through `lib/state-path-guard.sh`. Counts-only convergence remains the fallback when a round dir is absent, and the report labels it.
- Decision (grilled, round 2): the deep-review report name `report-<harness>.html` is a latest-run view per harness, matching `latest-<harness>.json`; only the gauntlet report is per-target and per-author (ledger stem).
- R1 is two blocks (authoring rule, summary-prose rule), each byte-identical across mirrors, because finding prose is authored in lens prompts, not only at report rendering. The finding summary line is exempt to keep `finding-key.sh` keys stable across rounds and resumed ledgers.
- The Phase 1 test checks block text, exact counts, the exemption sentence, anchor placement and the gate-1 sentence, not mere presence.
- `plugins/skein-pi` is out of scope (Pi-native rewrites with their own state, `.deep-review/latest-pi.json` and `lib/review_gauntlet.py`). A `docs/BACKLOG.md` entry tracks the follow-up.
- ASD-STE100 is a licensed spec with a large dictionary; the plan cites it as inspiration and encodes the rule as checkable items. No percentage claim. The licence statement is the author's understanding, not verified here.
- python3 is a soft dependency of the opt-in report; its absence yields a warning, not a failure.

### Dependencies
- None new for default runs. Python 3 stdlib only, and only for `--report`. Both plugin manifests are at 0.9.2; no version bump here (release goes through `skein:release`).

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| Reconciled envelope | gauntlet round loop (writes `$run_dir/round-N/reconciled.json`) / deep-review report step (audited envelope to a scratch temp file) | render-report.py via report-hook.sh (`--round N=` / `--envelope`) | Reconciler v2 envelope, `schema_version` 2 asserted; unknown fields ignored; gauntlet rows may lack `suggestion` and have null `line`; missing or malformed input yields a clear message and a non-zero renderer exit that the hook converts to a warning |
| Ledger | gauntlet ledger writers (existing) | render-report.py `--ledger` | Counts and key lists only; no `schema_version`; used for convergence rows and the counts-only fallback |
| Scope flags | orchestrator (resolved target variables) | report-hook.sh | `--base/--head`, `--uncommitted` or `--pr <N>`; none given renders "diff scope unavailable" |
| Diff stat file | report-hook.sh | render-report.py `--diff-stat` | Plain `--stat` text, labelled with capture mode and time; absent flag renders "diff scope unavailable" and exits 0; given-but-unreadable path exits non-zero |
| Output path | orchestrator guard (tree owner), then report-hook.sh (`--root`, `--out`) | render-report.py | Orchestrator guard first; renderer refuses out-of-root, symlink or `..` paths as defence in depth; writes via temp file and rename |
| Rule blocks A and B | Phase 1 | parity test | Per-block byte-identical across their file sets; exact counts asserted (A = 11, B = 3 per mirror); gate-1 sentence string-asserted |
| Bundle map | `scripts/lib/bundle-map.sh` (`BUNDLE_REPORT`) | `check-sync.sh`, `bundle-appliers.sh` | Every bundled copy byte-identical to canonical; Pi gets none (asserted in the bundle-parity test); no undeclared files |
| `$run_dir` | gauntlet SKILL.md round loop (both mirrors) | report hook | `.gauntlet/<ledger-stem>/` via `lib/state-path-guard.sh`; removed on `--fresh`; `round_n` from the ledger on `--resume`; absent round dirs trigger the counts-only fallback |

## Architecture & Call Flow

Component graph — which component triggers which:

```mermaid
graph LR
    G["review-gauntlet orchestrator"] -->|"gate 2: --verbose only"| D["deep-review orchestrator"]
    G -->|"opt-in --report"| HK["report-hook.sh"]
    D -->|"opt-in --report"| HK
    HK -->|"envelopes + ledger + diff-stat + --root/--out"| R["render-report.py"]
    R -->|"writes (contained)"| O1[".gauntlet/stem.report.html"]
    R -->|"writes (contained)"| O2[".deep-review/report-harness.html"]
    G -->|"writes via guards"| LG["ledger"]
    G -->|"writes via state-path-guard"| RD["round dirs under run_dir"]
    RD -->|"reconciled.json"| HK
    LG -->|"counts"| HK
```

Trigger order — one gauntlet run with `--report`:

```mermaid
sequenceDiagram
    participant U as User
    participant G as gauntlet orchestrator
    participant RD as round dirs
    participant H as report-hook.sh
    participant R as render-report.py
    U->>G: run with --report
    G->>RD: per-round reconciled.json, ledger append
    G->>G: guard report path with tree owner
    G->>H: terminal exit, scope flags
    H->>H: python3 check, capture diff stat, check-ignore warn
    H->>R: ledger, round envelopes, diff-stat file, --root, --out
    R-->>H: HTML written or error
    H-->>G: exit 0 always, warning on error
```

Trigger order — one deep-review run with `--report`:

```mermaid
sequenceDiagram
    participant U as User
    participant D as deep-review orchestrator
    participant RC as reconcile and audit
    participant H as report-hook.sh
    participant R as render-report.py
    U->>D: run with --report
    D->>RC: raw lens findings
    RC-->>D: audited v2 envelope
    D->>D: write envelope to scratch temp file, guard report path
    D->>H: envelope path, scope flags
    H->>R: envelope path, diff-stat file, --root, --out
    R-->>H: HTML written or error
    H-->>D: exit 0 always, warning on error
```

Context lifecycle:

| Step | Trigger | Enters context | Cleared/persisted | Turn boundary |
|------|---------|----------------|-------------------|---------------|
| Round loop | gauntlet round | findings, envelopes | envelopes persisted under `$run_dir`; ledger counts persisted | none |
| Reconcile | deep-review report step | raw lens findings | audited envelope written to a scratch temp file, not under `.deep-review/`; not persisted as state | none |
| Report hook | run end | file paths and flags only | HTML persisted; no finding text enters orchestrator context | none |
| Render | hook call | none (separate process) | HTML file on disk | none |

## Testing Notes

- `just ci`, backgrounded with a Monitor (per project CLAUDE.md). Fixer briefs and fixer commits run `just ci`.
- Renderer fixtures: reconciled envelope with all severities plus a non-canonical severity (lands in "Other", after Minor); a gauntlet-shaped envelope generated from `lib/run-gate.sh reconcile` over pooled gate rows (`lens: <gate>`, absent `suggestion`, null `line`); duplicate findings across rounds (assert no double count, dedup comes from the envelope); unknown extra fields; a ledger-only (counts-only) fixture asserting the fallback label.
- Renderer failure vectors: missing file, malformed JSON, `schema_version` mismatch on an envelope, empty findings, empty envelope file, a given-but-unreadable `--diff-stat` path. Each yields a clear message and a non-zero exit. An absent `--diff-stat` flag is not a failure: it renders "diff scope unavailable" and exits 0. A fixture asserts the diff-stat capture label.
- Hook test with a failing-renderer stub: asserts exit 0, a warning, and no writes outside the output path (hash `.gauntlet/` before and after). Also asserts the python3-absent path, the not-ignored warning, and one case per scope mode (`--base/--head`, `--uncommitted`, `--pr`, none).
- Containment fixtures: symlinked output path, `..` path, out-of-root path; all refused by the renderer. A boundary test (like R7-G2a in `tests/gauntlet/test-gate-timeout.sh`) asserts the orchestrator-side guard refuses them first.
- HTML safety assertions, using a parser (python `html.parser`), not grep: no `<script`, `<link`, `<iframe`, `<object`, `<embed`, `<base`, `<form`, `<meta http-equiv`, no `on*=` attributes, no `javascript:` URLs, no CSS `@import` or `url(`, no external `src=`/`href=`; finding text containing `<script>`, quotes, `&` and attribute-breaking input is escaped. URLs inside finding text are allowed as escaped text.
- HTML structure checked positively: exactly one `<html>`, `<head>`, `<body>`; expected sections present in severity order with "Other" last.
- Default-unchanged: shape assertions in both mirrors that the report step and flag are gated on `--report`, in both gauntlet and deep-review, plus assertions that gate 2 never receives `--report`, that every gauntlet terminal exit routes through the one report step, and that deep-review's argument-rule sentences list `--report` as a rendering-mode modifier. Each lands in the step that adds the flag.
- Bundle guard: widened §7 regex catches a `.py` reference with no `bundle_extra_for`/`BUNDLE_REPORT` entry; a Pi section asserts Pi's skill `scripts/` hold no copy and equal canonical minus `BUNDLE_REPORT`.
- Phase 1 parity test: per-block byte-compare, exact counts (A = 11, B = 3 per mirror), exemption sentence, anchor placement outside the GENERIC block, gate-1 sentence in both mirrors.
- Phase 3 test: three triggers and `--report` pointer present in both mirrors; anchored new bullets byte-identical.

## Acceptance Criteria

- Blocks A and B present with the exact counts and byte-identical per block; the gate-1 sentence present in both mirrors; `finding-key.sh` inputs untouched; Phase 1 changes no existing test.
- `just check-sync` green with the report group bundled; mirrors byte-identical to canonical; `plugins/skein-pi` holds no copy, asserted by a test.
- Fixture-based renderer and hook tests green, including failure, containment and safety vectors.
- Default (no `--report`) gauntlet and deep-review output unchanged, asserted by the shape tests.
- `show-me` lists the three triggers and the `--report` pointer in both mirrors; new test green.
- `$run_dir` defined in both gauntlet mirrors with its ledger-tied lifecycle; gauntlet shape tests green.
- `just ci` green; Codex halves (including `native_gates.py`) authored via `codex:rescue`.
- Manual dogfood (not CI, recorded in `## Final Results`): run `scripts/render-report.py` directly on the state the installed gauntlet leaves; expect the counts-only fallback until the next release refreshes the plugin cache, after which run the full `--report` path.
- `docs/BACKLOG.md` has the Pi follow-up entry.

<!-- reviewed: YYYY-MM-DD @ <hash> -->
<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 1: Plain-prose rule (R1)
- [ ] Phase 2: HTML report (R2)
- [ ] Phase 3: show-me triggers (R3)

## Findings

- (append findings here as work proceeds; Phase 2 step 1 records the per-round data decision here)

## Issues & Solutions

(none yet)

## Final Results

(fill when complete)
