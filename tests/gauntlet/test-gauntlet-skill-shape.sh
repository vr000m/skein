#!/usr/bin/env bash
# test-gauntlet-skill-shape.sh — Phase 1 acceptance: the Claude review-gauntlet
# SKILL.md documents the conductor contract: frontmatter/trigger phrases, the
# three gate slots, Option A split delegation, the convergence algorithm
# surface, both guardrails, the three invocation modes, <untrusted-content>
# wrapping, and reuse of the bundled scripts (never a relative-path fork of
# deep-review's).
#
# Plan: docs/dev_plans/20260707-feature-review-gauntlet-skill.md, Phase 1
# "Core orchestrator SKILL.md (Claude)". This is a pure documentation/shape
# check over plugins/skein/skills/review-gauntlet/SKILL.md, matching the
# goal-field trio's approach (tests/gauntlet/test-goal-field-schema.sh,
# tests/gauntlet/test-goal-injection.sh, tests/gauntlet/test-goal-docs.sh) —
# no runtime behaviour is exercised here (that is Phase 2's
# convergence-ledger.sh unit suite).
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SKILL_MD="$ROOT_DIR/plugins/skein/skills/review-gauntlet/SKILL.md"

pass_count=0
fail_count=0

pass() {
	echo "PASS: $1"
	pass_count=$((pass_count + 1))
}

fail() {
	echo "FAIL: $1"
	fail_count=$((fail_count + 1))
}

require_file() {
	local file="$1"
	if [[ ! -f "$file" ]]; then
		fail "file missing: $file"
		return 1
	fi
	return 0
}

# assert_grep FILE PATTERN LABEL
# PATTERN is passed to `grep -Eq` (extended regex) against the whole file.
assert_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (pattern not found: $pattern in $file)"
	fi
}

# assert_grep_i FILE PATTERN LABEL — case-insensitive variant.
assert_grep_i() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eqi -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label (pattern not found, case-insensitive: $pattern in $file)"
	fi
}

# assert_grep_fixed FILE STRING LABEL — literal (non-regex) substring match.
assert_grep_fixed() {
	local file="$1" needle="$2" label="$3"
	if grep -Fq -- "$needle" "$file"; then
		pass "$label"
	else
		fail "$label (literal string not found: $needle in $file)"
	fi
}

# assert_not_grep FILE PATTERN LABEL — asserts PATTERN is absent.
assert_not_grep() {
	local file="$1" pattern="$2" label="$3"
	if grep -Eq -- "$pattern" "$file"; then
		fail "$label (forbidden pattern found: $pattern in $file)"
	else
		pass "$label"
	fi
}

require_file "$SKILL_MD" || exit 1

# --- Frontmatter -------------------------------------------------------

assert_grep "$SKILL_MD" '^name:[[:space:]]*review-gauntlet[[:space:]]*$' \
	"frontmatter has \`name: review-gauntlet\`"

assert_grep "$SKILL_MD" '^description:' \
	"frontmatter has a \`description\` field"

assert_grep_i "$SKILL_MD" 'review gauntlet' \
	"description includes trigger phrase \"review gauntlet\""

assert_grep_i "$SKILL_MD" 'run the review gates' \
	"description includes trigger phrase \"run the review gates\""

assert_grep_i "$SKILL_MD" 'run all reviews' \
	"description includes trigger phrase \"run all reviews\""

assert_grep_i "$SKILL_MD" 'review loop until clean' \
	"description includes trigger phrase \"review loop until clean\""

assert_grep "$SKILL_MD" '^argument-hint:' \
	"frontmatter has an \`argument-hint\` field"

# --- Three gate slots -----------------------------------------------------

assert_grep "$SKILL_MD" 'codex exec review' \
	"documents gate 1 (adversarial Codex-review, \`codex exec review\`)"

assert_grep "$SKILL_MD" 'deep-review' \
	"documents gate 2 (\`deep-review\`)"

assert_grep "$SKILL_MD" '/security-review' \
	"documents gate 3 (security-review, \`/security-review\`)"

assert_grep "$SKILL_MD" '/code-review.*is not a gate|not a gate here' \
	"documents that \`/code-review\` is not a gate here"

# --- Option A / split delegation ----------------------------------------

assert_grep_i "$SKILL_MD" 'option a' \
	"references \"Option A\" split-delegation pattern"

assert_grep_i "$SKILL_MD" '(top level|top-level)' \
	"documents multi-spawn gates running at the conductor's top level"

assert_grep_i "$SKILL_MD" 'clean.context (subagent|sub-agent)' \
	"documents the fixer as the clean-context subagent"

# --- Convergence algorithm surface ---------------------------------------

assert_grep_i "$SKILL_MD" 'structural' \
	"documents \`structural\` blast-radius classification"

assert_grep_i "$SKILL_MD" 'restart' \
	"documents restarting from gate 1 on a structural fix"

assert_grep_i "$SKILL_MD" '\blocal\b' \
	"documents \`local\` blast-radius classification"

assert_grep_i "$SKILL_MD" 'confirm' \
	"documents the single confirming pass for local-only fixes"

assert_grep_i "$SKILL_MD" '(clean|zero actionable).*full|full.*(clean|zero actionable)' \
	"documents a clean \`full\` pass as the success stop condition"

assert_grep "$SKILL_MD" '10.loop|10-loop|cap of 10' \
	"documents the hard cap of 10 loops"

assert_grep_i "$SKILL_MD" 'K=2|two consecutive' \
	"documents non-convergence bail at K=2 consecutive rounds"

assert_grep "$SKILL_MD" 'success_with_quarantine' \
	"documents the \`success_with_quarantine\` terminal status"

# --- Both guardrails -------------------------------------------------------

assert_grep_i "$SKILL_MD" 'guardrail 1' \
	"documents Guardrail 1 heading/label"

assert_grep_i "$SKILL_MD" 'design.conflict' \
	"documents design-conflict findings as never auto-fixed"

assert_grep "$SKILL_MD" '\*\*Goal:\*\*' \
	"documents the dev-plan \`**Goal:**\` field as the design-intent source"

assert_grep_i "$SKILL_MD" 'quarantine' \
	"documents quarantine-vs-halt handling by blast radius"

assert_grep_i "$SKILL_MD" 'guardrail 2' \
	"documents Guardrail 2 heading/label"

assert_grep_i "$SKILL_MD" 'regardless of confidence' \
	"documents fix-all-regardless-of-confidence"

assert_grep_i "$SKILL_MD" 'only.*(quarantine trigger|trigger.*quarantine)|quarantine trigger.*only' \
	"documents design conflict as the only quarantine trigger"

assert_grep_i "$SKILL_MD" 'guardrail 3' \
	"documents Guardrail 3 heading/label"

assert_grep_i "$SKILL_MD" 'regression test' \
	"documents the regression-test requirement for substantive fixes"

assert_grep_i "$SKILL_MD" 'guardrail 4' \
	"documents Guardrail 4 heading/label"

assert_grep "$SKILL_MD" 'git status --short' \
	"documents verifying the fixer's claims against live repo state"

assert_grep_i "$SKILL_MD" 'guardrail 5' \
	"documents Guardrail 5 heading/label"

assert_grep "$SKILL_MD" 'just ci' \
	"documents the full-CI requirement on every fixer brief and after every fixer commit"

# --- Invocation modes ------------------------------------------------------

assert_grep_i "$SKILL_MD" 'standalone' \
	"documents the standalone invocation mode"

assert_not_grep "$SKILL_MD" 'quick.*(single.pass|no.loop|no convergence loop)|(single.pass|no.loop|no convergence loop).*quick' \
	"does not document a Claude-side \`quick\` single-pass mode (removed with the code-review gate)"

assert_grep "$SKILL_MD" '\bfull\b' \
	"documents the \`full\` invocation mode"

assert_grep_i "$SKILL_MD" 'no single-pass mode' \
	"documents that there is no single-pass mode anymore"

# --- <untrusted-content> wrapping ------------------------------------------

assert_grep "$SKILL_MD" '<untrusted-content>' \
	"references \`<untrusted-content>\` wrapping for plan/diff content passed to subagents"

# --- Reuse: bundled scripts, no relative-path fork -------------------------

# Round 9, F10: this used to assert the mirror NAMES `reconcile-findings.sh`.
# It no longer may — cross-gate dedup goes through `run-gate.sh reconcile`,
# which IS the bundled reconciler invoked with no `--skill` plus the positional
# symlink guard, so a direct call would bypass round 8's `read_input`
# hardening. R9-G6a below is the positive form (all four subcommands present as
# runnable invocations in BOTH mirrors) and also forbids the direct call; what
# survives here is the no-`--skill` rule, restated against the dispatcher.
assert_not_grep "$SKILL_MD" 'run-gate\.sh reconcile[^\n]*--skill' \
	"does not pass \`--skill\` to \`run-gate.sh reconcile\`"

assert_grep "$SKILL_MD" 'apply-auto-fix-code\.sh' \
	"references the bundled \`apply-auto-fix-code.sh\`"

assert_grep "$SKILL_MD" '\$\{CLAUDE_PLUGIN_ROOT\}' \
	"uses \${CLAUDE_PLUGIN_ROOT} anchors"

assert_not_grep "$SKILL_MD" '\.\./\.\./deep-review/scripts/' \
	"does not reference \`../../deep-review/scripts/\` (relative-path fork)"

# --- Gate order: the three gates must appear in the fixed sequence --------
# Membership alone (each gate mentioned somewhere) does not prove the SKILL.md
# documents the fixed run order (adversarial -> deep-review -> security-review).
# Pin the order by asserting each gate's line number is strictly increasing.

adversarial_line="$(grep -n -m1 -E '\*\*Adversarial Codex-review gate\.\*\*' "$SKILL_MD" | cut -d: -f1 || true)"
deep_review_line="$(grep -n -m1 -E '\*\*.skein:deep-review.* \(5 lenses\)\.\*\*' "$SKILL_MD" | cut -d: -f1 || true)"
security_review_line="$(grep -n -m1 -E '\*\*Security-review gate\.\*\*' "$SKILL_MD" | cut -d: -f1 || true)"

if [[ -n "$adversarial_line" && -n "$deep_review_line" && -n "$security_review_line" ]] &&
	((adversarial_line < deep_review_line && deep_review_line < security_review_line)); then
	pass "gate order is fixed: adversarial ($adversarial_line) < deep-review ($deep_review_line) < security-review ($security_review_line)"
else
	fail "gate order is not the fixed adversarial -> deep-review -> security-review sequence (lines: $adversarial_line, $deep_review_line, $security_review_line)"
fi

# --- Fixer-dispatch co-location: <untrusted-content> and Goal/design-intent
# must appear together, not just independently somewhere in the file. Assert
# they co-occur within the same paragraph as the "must include both" sentence.

fixer_dispatch_para="$(awk '/Every fixer dispatch in this skill must include/{print; found=1; next} found && NF==0{exit} found{print}' "$SKILL_MD")"
if [[ -n "$fixer_dispatch_para" ]] &&
	grep -q '<untrusted-content>' <<<"$fixer_dispatch_para" &&
	grep -qE '\*\*Goal:\*\*|design-intent' <<<"$fixer_dispatch_para"; then
	pass "fixer-dispatch paragraph co-locates <untrusted-content> wrap with the Goal/design-intent reference"
else
	fail "fixer-dispatch paragraph does not co-locate <untrusted-content> wrap with the Goal/design-intent reference"
fi

# --- Sanity: non-empty / non-truncation guard ------------------------------

if [[ -s "$SKILL_MD" ]]; then
	pass "$(basename "$SKILL_MD") is non-empty"
else
	fail "$(basename "$SKILL_MD") is empty"
fi

# A gross truncation could otherwise vacuously satisfy sparse greps above;
# require a minimum line count consistent with a real conductor SKILL.md.
line_count="$(wc -l <"$SKILL_MD" | tr -d '[:space:]')"
if [[ "$line_count" -ge 80 ]]; then
	pass "SKILL.md has a substantive line count ($line_count >= 80)"
else
	fail "SKILL.md looks truncated (only $line_count lines, expected >= 80)"
fi

# --- Resume shape (Phase 3): both mirrors, not just Claude ----------------
# Plan: docs/dev_plans/20260710-feature-review-gauntlet-resume.md, Phase 3.
# Loops over both mirror SKILL.md files (the pre-existing checks above are
# Claude-specific gate/label phrasing; this section is scoped to the
# resume-specific contract, which both mirrors document identically).

CODEX_SKILL_MD="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/SKILL.md"

assert_resume_shape_for() {
	local file="$1" label="$2" anchor_pattern="$3" ledger_invoke_prefix="$4"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	assert_grep "$file" '\-\-resume' \
		"$label: documents \`--resume\`"

	assert_grep "$file" '\-\-fresh' \
		"$label: documents \`--fresh\`"

	assert_grep "$file" 'pr:<N>' \
		"$label: documents the canonical target scheme's \`pr:<N>\` form"

	assert_grep "$file" 'branch:<' \
		"$label: documents the canonical target scheme's \`branch:<...>\` form"

	assert_grep_i "$file" 'does not unify|deliberately.*not.*unify|distinct scope' \
		"$label: states the cross-surface (PR vs. branch) scoping limitation"

	assert_grep_i "$file" 'resume decision table' \
		"$label: has a Resume Decision Table section"

	assert_grep "$file" 'exit 0.*continue|continue.*exit 0' \
		"$label: decision table documents exit 0 -> continue (non-terminal)"

	assert_grep "$file" 'exit 4' \
		"$label: decision table documents exit 4 (missing ledger)"

	assert_grep "$file" 'exit 5' \
		"$label: decision table documents exit 5 (terminal)"

	assert_grep "$file" 'success_with_quarantine.*cap.*non-converge|success.*success_with_quarantine.*cap.*non-converge' \
		"$label: exit-5 terminal row names all four terminal tokens (success/success_with_quarantine/cap/non-converge), not just success"

	assert_grep_i "$file" 'what resume cannot restore' \
		"$label: has a \"What Resume Cannot Restore\" section"

	assert_grep_i "$file" 'mid-round' \
		"$label: \"What Resume Cannot Restore\" documents the mid-round-loss gap"

	assert_grep_i "$file" 'worktree teardown|worktree.*not resumable|not resumable.*worktree' \
		"$label: \"What Resume Cannot Restore\" documents the worktree-teardown gap"

	assert_grep "$file" 'gc_ledger_path' \
		"$label: references \`gc_ledger_path\`"

	assert_grep_i "$file" 'source.*gauntlet-common\.sh|gauntlet-common\.sh.*source|^\. ".*gauntlet-common\.sh"|\. "\$' \
		"$label: documents sourcing \`gauntlet-common.sh\` before calling \`gc_ledger_path\` (it is a shell function, not an executable)"

	assert_grep "$file" "$anchor_pattern" \
		"$label: uses its harness-specific plugin-root anchor ($anchor_pattern) for the sourcing prelude"

	# Write-side wiring: the loop-entry --init call and the per-round append
	# call must both bind gc_ledger_path's output via --ledger and pass
	# --target — without this, --resume has nothing to read.
	assert_grep_fixed "$file" "${ledger_invoke_prefix}/lib/convergence-ledger.sh --init --ledger \"\$ledger_path\" --target \"\$canonical_target\"" \
		"$label: write-side wiring documents \`--init --ledger \$ledger_path --target \$canonical_target\` at loop entry"

	assert_grep_fixed "$file" "${ledger_invoke_prefix}/lib/convergence-ledger.sh --init --force --ledger \"\$ledger_path\" --target \"\$canonical_target\"" \
		"$label: write-side wiring documents \`--fresh\` mapping to \`--init --force\`"

	# The per-round append call binds --ledger/--target either as a direct
	# literal invocation (Claude mirror) or, since the Phase 3 C1/C2 wiring
	# needs to conditionally append --claimed-keys, via a `ledger_args=(...)`
	# array built up before a single `convergence-ledger.sh "${ledger_args[@]}"`
	# call (Codex mirror) -- accept either form, not just the literal one.
	if grep -Fq "${ledger_invoke_prefix}/lib/convergence-ledger.sh --ledger \"\$ledger_path\" --target \"\$canonical_target\" --count" "$file" ||
		grep -Fq "ledger_args=(--ledger \"\$ledger_path\" --target \"\$canonical_target\" --count" "$file"; then
		pass "$label: write-side wiring documents the per-round append call binding \`--ledger \$ledger_path --target \$canonical_target\` (direct call or ledger_args array)"
	else
		fail "$label: write-side wiring documents the per-round append call binding \`--ledger \$ledger_path --target \$canonical_target\` (direct call or ledger_args array) (neither form found)"
	fi
}

assert_resume_shape_for "$SKILL_MD" "Claude mirror" '\$\{CLAUDE_PLUGIN_ROOT\}' '"${CLAUDE_PLUGIN_ROOT}"/skills/review-gauntlet'
assert_resume_shape_for "$CODEX_SKILL_MD" "Codex mirror" '\$SKILL_DIR' '"$SKILL_DIR"'

# --- Phase 1: bounded Codex gate + size-scaled budgets ---------------------
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 1
# R1/R2. Gate 1's invocation must go through the shell-enforced budget
# wrapper (never a Claude-side-only mechanism), sized via lens-budget.sh
# --kind codex, on BOTH mirrors (R10: every skill change is mirrored in the
# same phase). Monitor is documented as advisory/non-load-bearing and
# Claude-only, so it is asserted only on the Claude mirror.

assert_phase1_gate_bound_shape_for() {
	local file="$1" label="$2"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	assert_grep_i "$file" 'gate_run_bounded|gate-bounded\.sh' \
		"$label: gate 1 invocation goes through the gate_run_bounded helper (lib/gate-bounded.sh), not a bare \`codex exec review\` call"

	assert_grep_fixed "$file" 'lens-budget.sh' \
		"$label: gate 1's budget is sourced from lens-budget.sh, not a hardcoded number"

	assert_grep_fixed "$file" '--kind codex' \
		"$label: gate 1 requests the codex kind from lens-budget.sh (20m floor / 45m cap)"

	assert_grep_i "$file" 'skipped|DEGRADED' \
		"$label: documents the on-expiry outcome as skipped/DEGRADED, never silently clean"
}

assert_phase1_gate_bound_shape_for "$SKILL_MD" "Claude mirror"
assert_phase1_gate_bound_shape_for "$CODEX_SKILL_MD" "Codex mirror"

assert_grep_i "$SKILL_MD" 'monitor' \
	"Claude mirror: documents Monitor as the (advisory) Claude-side UX layer over the shell-enforced budget"

assert_grep_i "$SKILL_MD" 'monitor.*(non-load-bearing|not load-bearing|advisory|optional)|(non-load-bearing|not load-bearing|advisory|optional).*monitor' \
	"Claude mirror: states Monitor is non-load-bearing/advisory — the shell timeout is what actually bounds the gate"

# R2: the flag combination behind the 90+ minute Codex hang is either named
# outright ("Forbidden flags:") or explicitly marked UNVERIFIED with the
# budget documented as the sole defence — never shipped as an unconfirmed
# fact with no marker at all, and never claimed as fact without verification.
# Acceptance: "test-gauntlet-skill-shape.sh accepts exactly one of the two
# forms" — so this must be an XOR, not an OR.

assert_r2_forbidden_flags_xor_for() {
	local file="$1" label="$2"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	local has_forbidden=0 has_unverified=0
	grep -Fq 'Forbidden flags:' "$file" && has_forbidden=1
	if grep -Eqi 'UNVERIFIED' "$file" && grep -Eqi 'budget' "$file" &&
		grep -Eqi '(sole|only) (defen[cs]e)' "$file"; then
		has_unverified=1
	fi

	if [[ $((has_forbidden + has_unverified)) -eq 1 ]]; then
		pass "$label: R2 carries exactly one of {'Forbidden flags:' line, UNVERIFIED-marker-with-budget-as-sole-defence} (forbidden=$has_forbidden, unverified=$has_unverified)"
	else
		fail "$label: R2 must carry EXACTLY ONE of {'Forbidden flags:' line, UNVERIFIED-marker-with-budget-as-sole-defence}, found forbidden=$has_forbidden unverified=$has_unverified (never both, never neither — an unconfirmed fact must not ship unmarked)"
	fi
}

assert_r2_forbidden_flags_xor_for "$SKILL_MD" "Claude mirror"
assert_r2_forbidden_flags_xor_for "$CODEX_SKILL_MD" "Codex mirror"

# --- Phase 3: regression-loop stop + gate-status rows (both mirrors) -------
# Plan: docs/dev_plans/20260823-feature-review-skills-resilience.md, Phase 3,
# R5/R6/R7. Fixer output schema is now `{claimed:[key...]}` (the ledger owns
# claimed->fixed promotion; the orchestrator/fixer only ever reports what it
# observes/claims). Stop condition 5 (regression) must be documented
# alongside the pre-existing four terminal conditions. R6 (a confirm-subset
# lens-selection flag for deep-review) was grilled and dropped — its
# rationale must not resurface as a shipped requirement. status-row's column
# names must be documented so a reader can map SKILL.md prose to the script's
# actual output shape.

assert_phase3_regression_status_shape_for() {
	local file="$1" label="$2"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	assert_grep_fixed "$file" '{claimed:' \
		"$label: documents the fixer output schema \`{claimed:[key...]}\`"

	assert_grep_i "$file" 'ledger.*(owns|is responsible for).*(claimed|promot)|(claimed|promot).*ledger.*(owns|is responsible for)' \
		"$label: documents that the ledger itself (not the orchestrator) owns claimed->fixed promotion"

	assert_grep_i "$file" 'stop condition 5|5\. ?regression|regression.*stop condition' \
		"$label: documents stop condition 5 (regression)"

	assert_grep_i "$file" 'regression' \
		"$label: documents the \`regression\` terminal decision token"

	assert_not_grep "$file" 'confirm-subset' \
		"$label: does not resurface the dropped R6 confirm-subset lens-selection mechanism"

	assert_grep_i "$file" 'status-row' \
		"$label: references \`status-row\` (the script-emitted gate-status row command)"

	# Column names: gate, status, duration_s, findings, degraded_reason.
	assert_grep_i "$file" '\bgate\b' \
		"$label: status-row documentation names the \`gate\` column"

	assert_grep_i "$file" '\bstatus\b' \
		"$label: status-row documentation names the \`status\` column"

	assert_grep_fixed "$file" 'duration_s' \
		"$label: status-row documentation names the \`duration_s\` column"

	assert_grep_i "$file" '\bfindings\b' \
		"$label: status-row documentation names the \`findings\` column"

	assert_grep_fixed "$file" 'degraded_reason' \
		"$label: status-row documentation names the \`degraded_reason\` column"

	assert_grep_fixed "$file" 'run-gate.sh status-row' \
		"$label: documents rows as \`run-gate.sh status-row\`-emitted (script-emitted, not authored in SKILL.md prose)"
}

assert_phase3_regression_status_shape_for "$SKILL_MD" "Claude mirror"
assert_phase3_regression_status_shape_for "$CODEX_SKILL_MD" "Codex mirror"

# Status rows must be documented as printed BEFORE the ledger decision each
# round -- membership alone (both phrases appear somewhere) does not prove
# the ordering, so pin it the same way the gate-order check above does.

# G11: this assertion used to compute `decision_line` and never read it, so
# it passed for ANY file containing both phrases in any order -- including
# the exact reordering it claims to forbid. It now compares both numbers.
#
# DEVIATION FROM THE r1 FIX DESIGN (deliberate, recorded): the design said
# to compare the FIRST `status-row` mention against the FIRST
# `convergence-ledger.sh` mention. That rule is wrong against the real
# files and would fail BOTH mirrors. Their first `convergence-ledger.sh`
# references are the `--init`/`--last-decision` setup calls (Claude :54,
# Codex :52), which legitimately precede the whole per-round runbook. The
# ordering this test is actually about is "print the gate-status rows
# BEFORE recording the round and taking its decision", so the anchors are:
#   - status row = the FIRST `/run-gate.sh status-row` INVOCATION line
#     (path-prefixed, so a prose mention never anchors it);
#   - decision   = the LAST path-prefixed `convergence-ledger.sh`
#     invocation line -- the round-recording call (Claude's `--count ...`
#     at :252, Codex's `"${ledger_args[@]}"` at :325).
# Both anchors must exist, and the row must come strictly first.
status_row_before_decision_lines() {
	# Echoes "<status_row_line> <decision_line>"; either may be empty.
	local file="$1"
	local srl dl
	srl="$(grep -n '/run-gate\.sh status-row' "$file" | head -1 | cut -d: -f1 || true)"
	dl="$(grep -n '/convergence-ledger\.sh' "$file" | tail -1 | cut -d: -f1 || true)"
	# Trailing newline matters: `read` returns non-zero on EOF-without-
	# delimiter, which `set -e` would turn into an abort.
	printf '%s %s\n' "$srl" "$dl"
}

assert_status_row_before_decision_for() {
	local file="$1" label="$2"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	local status_row_line decision_line
	read -r status_row_line decision_line < <(status_row_before_decision_lines "$file") || true

	if [[ -z "$status_row_line" ]]; then
		fail "$label: no \`run-gate.sh status-row\` invocation line found, cannot verify print-before-decision ordering"
		return
	fi
	if [[ -z "$decision_line" ]]; then
		fail "$label: no \`convergence-ledger.sh\` invocation line found, cannot verify print-before-decision ordering"
		return
	fi
	if ((status_row_line < decision_line)); then
		pass "$label: status-row invocation (line $status_row_line) precedes the ledger decision call (line $decision_line)"
	else
		fail "$label: status-row invocation (line $status_row_line) must PRECEDE the ledger decision call (line $decision_line)"
	fi
}

assert_status_row_before_decision_for "$SKILL_MD" "Claude mirror"
assert_status_row_before_decision_for "$CODEX_SKILL_MD" "Codex mirror"

# NEGATIVE CONTROL -- the assertion must BITE on the ordering it forbids.
# Truncating the Claude mirror just after its first status-row invocation
# drops the round-recording ledger call, leaving the setup-section ledger
# invocations as the LAST ones: decision_line then precedes status_row_line,
# which is exactly the reordering this test claims to forbid. Without this
# control a future refactor could silently neuter the assertion again the
# way G11 found it.
negative_control_ordering() {
	local srl tmp rsrl rdl
	srl="$(grep -n '/run-gate\.sh status-row' "$SKILL_MD" | head -1 | cut -d: -f1 || true)"
	if [[ -z "$srl" ]]; then
		fail "negative control: no status-row invocation line to build a reordered fixture from"
		return
	fi
	tmp="$(mktemp)"
	head -n "$srl" "$SKILL_MD" >"$tmp"
	read -r rsrl rdl < <(status_row_before_decision_lines "$tmp") || true
	if [[ -n "$rsrl" && -n "$rdl" ]] && ((rsrl >= rdl)); then
		pass "negative control: the ordering assertion reports a violation when the ledger decision precedes the status row (row=$rsrl decision=$rdl)"
	else
		fail "negative control: the ordering assertion did NOT bite on a reordered fixture (row='$rsrl' decision='$rdl')"
	fi
	rm -f "$tmp"
}
negative_control_ordering

# --- Phase 3 fix spec (F1-F6, C1-C3): row-count-per-mirror, envelope-
# variable-assigned, deferred-promotion prose, and --gate stamping ---------
# Plan: .conduct/phase3-fix-spec.md. These are the assertions that would
# have caught F5/C1 (undeclared envelope_* variables) and C3 (only 2 of 4
# Codex slots emitted a row) directly, rather than by grepping for
# membership of individual phrases.

# assert_status_row_line_count FILE EXPECTED_COUNT LABEL — exactly N lines
# invoking `run-gate.sh status-row` (the per-gate-slot table row call, not
# any other mention of the string "status-row" in prose).
assert_status_row_line_count() {
	local file="$1" expected="$2" label="$3"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	# Match only actual invocation lines (a leading path segment before
	# run-gate.sh, e.g. "${CLAUDE_PLUGIN_ROOT}/.../lib/run-gate.sh
	# status-row" or "\"$SKILL_DIR\"/lib/run-gate.sh status-row"), never a
	# backtick-quoted bare mention in prose ("run `run-gate.sh status-row`
	# and print the row it emits").
	local actual
	actual="$(grep -c '/run-gate\.sh status-row' "$file" 2>/dev/null || echo 0)"
	if [[ "$actual" -eq "$expected" ]]; then
		pass "$label: exactly $expected \`run-gate.sh status-row\` invocation line(s) (one per gate slot)"
	else
		fail "$label: expected exactly $expected \`run-gate.sh status-row\` invocation line(s), found $actual"
	fi
}

assert_status_row_line_count "$SKILL_MD" 3 "Claude mirror"
assert_status_row_line_count "$CODEX_SKILL_MD" 4 "Codex mirror"

# assert_envelope_vars_assigned_for FILE LABEL — every envelope_* variable
# dereferenced on a `status-row` invocation line is also assigned (via a
# bare `envelope_x=...` or `> "$envelope_x"` construction-target) somewhere
# earlier in the same file. This is the assertion that would have caught
# F5/C1 directly: SKILL.md referencing $envelope_deep_review/
# $envelope_security_review in the status-row block when nothing upstream
# ever assigned them.
assert_envelope_vars_assigned_for() {
	local file="$1" label="$2"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	local status_row_lines var_names var missing=0 checked=0
	status_row_lines="$(grep 'run-gate\.sh status-row' "$file" 2>/dev/null || true)"
	if [[ -z "$status_row_lines" ]]; then
		fail "$label: no \`run-gate.sh status-row\` invocation lines found, cannot verify envelope-variable assignment"
		return
	fi

	var_names="$(printf '%s\n' "$status_row_lines" | grep -oE '\$envelope_[A-Za-z0-9_]+' | tr -d '$' | sort -u)"
	if [[ -z "$var_names" ]]; then
		fail "$label: no \$envelope_* variables referenced on any status-row line -- cannot verify"
		return
	fi

	while IFS= read -r var; do
		[[ -n "$var" ]] || continue
		checked=$((checked + 1))
		# An "assignment" is either a bare shell assignment (envelope_x=...)
		# or the variable appearing as a redirection target
		# (> "$envelope_x" / >"$envelope_x") -- both patterns used in these
		# SKILL.md files' fenced code blocks.
		if grep -qE "^${var}=" "$file" || grep -qE ">\\s*\"?\\\$${var}\"?" "$file"; then
			:
		else
			missing=$((missing + 1))
			fail "$label: \$${var} is referenced on a status-row line but never assigned anywhere earlier in the file"
		fi
	done <<<"$var_names"

	if [[ "$missing" -eq 0 && "$checked" -gt 0 ]]; then
		pass "$label: every \$envelope_* variable referenced on a status-row line ($checked checked) is assigned earlier in the file"
	fi
}

assert_envelope_vars_assigned_for "$SKILL_MD" "Claude mirror"
assert_envelope_vars_assigned_for "$CODEX_SKILL_MD" "Codex mirror"

# assert_phase3_deferred_and_gate_stamp_for FILE LABEL — F1 deferred-
# promotion prose (pending/next-full-pass language, never same-round) and
# F5 --gate stamping prose (gate_run_bounded's --gate flag documented as
# overriding/authoritative on gate identity across all exit paths).
assert_phase3_deferred_and_gate_stamp_for() {
	local file="$1" label="$2"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	assert_grep_i "$file" 'pending' \
		"$label: documents pending claims (deferred promotion state)"

	assert_grep_i "$file" 'next|later|subsequent' \
		"$label: documents promotion as deferred to a NEXT/LATER round, not the same round"

	assert_grep_fixed "$file" '--gate' \
		"$label: documents the \`--gate <name>\` flag"

	assert_grep_i "$file" 'gate_run_bounded' \
		"$label: documents \`gate_run_bounded\` (the shell helper that stamps gate identity)"

	assert_grep_i "$file" '(all three|every).*(exit path|path)|(exit path|path).*(all three|every)' \
		"$label: documents --gate stamping identity across ALL exit paths (clean, timeout, error) -- not just the clean path"
}

assert_phase3_deferred_and_gate_stamp_for "$SKILL_MD" "Claude mirror"
assert_phase3_deferred_and_gate_stamp_for "$CODEX_SKILL_MD" "Codex mirror"

# ---------------------------------------------------------------------------
# (G11) The convergence key-extraction block must be TOTAL under `set -u` and
# `pipefail`.
#
# Two ways it aborted the very round it was written to protect:
#   * `$auto_fix_manifest` is assigned only by capturing the applier's stderr
#     line, which does not happen when the applier never ran -- so
#     `[[ -s "$auto_fix_manifest" ]]` is an unbound-variable abort under
#     `set -u`, reintroducing the abort the surrounding guard prevents.
#   * step 1 used `.findings[]` while 2a used `.findings[]?`; a null or absent
#     `.findings` makes the unconditional form exit non-zero and, under
#     `pipefail`, aborts the round before any key file is written.
# Asserted on the extracted block so a future edit cannot silently regress it.
# ---------------------------------------------------------------------------

g11_check_block() {
	local file="$1" label="$2"

	# Asserted over the whole SKILL.md rather than an extracted range: the two
	# mirrors lay the convergence section out differently, and the patterns are
	# specific enough (they name the variable and the exact artifact) that a
	# file-wide check has no false-positive surface.
	# Comment lines are stripped first: the surrounding prose deliberately
	# NAMES the broken form when explaining why the guard exists, and that
	# must not read as the broken form still being present.
	local g11_code
	g11_code="$(grep -v '^[[:space:]]*#' "$file")"

	if printf '%s\n' "$g11_code" | grep -q '\[\[ -s "\$auto_fix_manifest" \]\]'; then
		fail "G11(a) ($label): an UNGUARDED \$auto_fix_manifest test remains (unbound-variable abort under set -u)"
	elif printf '%s\n' "$g11_code" | grep -q '\[\[ -s "\${auto_fix_manifest:-}" \]\]'; then
		pass "G11(a) ($label): the \$auto_fix_manifest test carries a :- default"
	else
		fail "G11(a) ($label): no recognisable \$auto_fix_manifest guard found"
	fi

	if printf '%s\n' "$g11_code" | grep -q 'auto_fix_manifest=""'; then
		pass "G11(b) ($label): \$auto_fix_manifest is initialised in the keys setup block (it has an owner)"
	else
		fail "G11(b) ($label): \$auto_fix_manifest is never initialised -- only defensively read"
	fi

	if printf '%s\n' "$g11_code" | grep -qF "jq -c '.findings[]' reconciled-envelope.json"; then
		fail "G11(c) ($label): an UNGUARDED .findings[] expansion remains (exits non-zero on a null/absent .findings, aborting the round under pipefail)"
	else
		pass "G11(c) ($label): the present-keys extraction is optional (.findings[]?), matching 2a"
	fi
}

g11_check_block "$SKILL_MD" "skein/review-gauntlet"
g11_check_block "$CODEX_SKILL_MD" "skein-codex/review-gauntlet"

# ---------------------------------------------------------------------------
# G12 (r4 F6) — the ledger's symlink guard is documented where the ledger is
# initialised.
#
# `ledger_assert_no_symlink` refuses (never redirects) a ledger path any of
# whose components inside the worktree is a symlink. The threat is a TRACKED
# symlink that materialises on checkout: a malicious clone points
# `.gauntlet/` outside the repo and every ledger write lands on an arbitrary
# user-writable file. An operator who does not know the guard exists reads its
# refusal as a bug and works around it -- which is exactly the wrong response,
# so the behaviour has to be stated, not inferred from a diagnostic.
# ---------------------------------------------------------------------------

g12_check_ledger_guard() {
	local file="$1" label="$2"
	if grep -qF 'ledger_assert_no_symlink' "$file"; then
		pass "G12(a) ($label): the ledger symlink guard is named"
	else
		fail "G12(a) ($label): the ledger-init prose never names ledger_assert_no_symlink"
	fi
	if grep -Eq 'tracked symlink' "$file"; then
		pass "G12(b) ($label): the tracked-symlink-on-checkout threat is stated"
	else
		fail "G12(b) ($label): the tracked-symlink-on-checkout threat is not stated"
	fi
	if grep -Eq 'refuses[^.]*never redirect' "$file"; then
		pass "G12(c) ($label): the refuse-never-redirect behaviour is stated"
	else
		fail "G12(c) ($label): the refuse-never-redirect behaviour is not stated"
	fi
}

g12_check_ledger_guard "$SKILL_MD" "skein/review-gauntlet"
g12_check_ledger_guard "$CODEX_SKILL_MD" "skein-codex/review-gauntlet"

# ---------------------------------------------------------------------------
# R7-G7a — every AUTHORED lib file is documented in BOTH SKILL.md mirrors.
#
# `lib/state-path-guard.sh` shipped in round 6 registered in
# GAUNTLET_LIB_PARITY_FILES and sourced by three siblings, but named nowhere
# in the skill's own prose. Generalised so the NEXT lib file cannot ship
# undocumented either: the parity list is the source of truth for what is
# authored here, so drive the assertion off it.
#
# The mention must be a BARE `lib/<name>` — no ${CLAUDE_PLUGIN_ROOT} /
# $SKILL_DIR anchor — because these files are never invoked as entrypoints;
# that also keeps the sentence identical in both mirrors for
# `just check-prompt-parity`.
r7g7_codex_md="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/SKILL.md"
r7g7_missing=""
for r7g7_f in $(sed -n 's/^GAUNTLET_LIB_PARITY_FILES=(\(.*\))$/\1/p' \
	"$ROOT_DIR/tests/parity/test-applier-bundle-parity.sh"); do
	grep -Fq "lib/$r7g7_f" "$SKILL_MD" || r7g7_missing="$r7g7_missing [claude:$r7g7_f]"
	grep -Fq "lib/$r7g7_f" "$r7g7_codex_md" || r7g7_missing="$r7g7_missing [codex:$r7g7_f]"
done
if [[ -z "$r7g7_missing" ]]; then
	pass "R7-G7a: every file in GAUNTLET_LIB_PARITY_FILES is named in BOTH SKILL.md mirrors"
else
	fail "R7-G7a: undocumented authored lib file(s):$r7g7_missing (Codex-mirror SKILL.md prose is applied by the codex-mirror agent — see .gauntlet/r7/codex-mirror-edits.md for the exact sentence)"
fi

# ---------------------------------------------------------------------------
# R9-G6a (round 9, F10) — BOTH mirrors must invoke the three run-gate.sh
# subcommands they promise, as RUNNABLE invocations rather than prose.
#
# The Claude mirror's own sentence claimed "the invocations below are its
# normalize/reconcile/route subcommands, in that order", but what followed was
# a DIRECT bundled-reconciler call, a `route` code block whose first line
# consumed `route_output.json` without ever showing the `route` call that
# produced it, and `status-row` — which is not one of the three. The Codex
# mirror carried all three, so the divergence was one-sided and invisible to
# `just check-prompt-parity` (which covers rubric.md/*-prompt.md, not this
# section). The consequence was concrete: round 8's `read_input` symlink guard
# justifies itself in-code with "SKILL.md composes it from the same
# $gate_out_dir" — true of the Codex prescriptions only, so on the Claude path
# the hardening guarded a call the harness was never told to make.
#
# "Runnable" is distinguished from prose by requiring the anchor prefix on the
# same line (`${CLAUDE_PLUGIN_ROOT}/…/lib/` or `"$SKILL_DIR"/lib/`), which
# prose references lack. The two anchors are harness-divergent BY DESIGN and
# are never collapsed.
# ---------------------------------------------------------------------------
r9g6_mirrors=(
	"$ROOT_DIR/plugins/skein/skills/review-gauntlet/SKILL.md"
	"$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/SKILL.md"
)
r9g6_bad=""
for r9g6_md in "${r9g6_mirrors[@]}"; do
	if [[ ! -f "$r9g6_md" ]]; then
		r9g6_bad="$r9g6_bad [missing $r9g6_md]"
		continue
	fi
	for r9g6_sub in normalize reconcile route status-row; do
		if ! grep -qE '("\$\{CLAUDE_PLUGIN_ROOT\}"/skills/review-gauntlet/lib/|"\$SKILL_DIR"/lib/)run-gate\.sh '"$r9g6_sub"'([[:space:]]|$)' "$r9g6_md"; then
			r9g6_bad="$r9g6_bad [$(basename "$(dirname "$(dirname "$(dirname "$r9g6_md")")")"): no runnable 'run-gate.sh $r9g6_sub' invocation]"
		fi
	done
	# The dispatcher is the SOLE route to gate output: no mirror may invoke a
	# bundled pipeline script that a run-gate.sh subcommand already wraps.
	if grep -qE 'scripts/reconcile-findings\.sh' "$r9g6_md"; then
		r9g6_bad="$r9g6_bad [$(basename "$(dirname "$(dirname "$(dirname "$r9g6_md")")")"): invokes scripts/reconcile-findings.sh directly instead of 'run-gate.sh reconcile']"
	fi
done
if [[ -z "$r9g6_bad" ]]; then
	pass "R9-G6a: both mirrors invoke run-gate.sh normalize/reconcile/route/status-row as runnable, anchored commands and neither calls the bundled reconciler directly"
else
	fail "R9-G6a:$r9g6_bad"
fi

# ---------------------------------------------------------------------------
# R10-A1a (round 10, F1/F2/F5) — the run-gate recipe must COMPOSE, not merely
# contain the four subcommands.
#
# R9-G6a asserts MEMBERSHIP: each subcommand appears as a runnable, anchored
# invocation. It says nothing about whether the blocks join, and three defects
# landed in that gap. `normalize` was handed `$gate_out_dir/<gate>-raw.json`,
# a name `gate_run_bounded` never writes (it writes `<name>.envelope.json` and
# `<name>.tool-out.json`, both declared 100 lines earlier in the paths block);
# `normalize` and `reconcile` emit to STDOUT and neither block redirected, so
# `findings.jsonl` and `reconciled.json` had no producer anywhere in the file;
# and the Codex mirror's `route` block lacked `> route_output.json` while the
# line after it read `route_output.json`.
#
# The invariant this asserts: within the recipe section, every file path a
# shown command CONSUMES is either a declared gate envelope or a path an
# earlier shown command PRODUCES. Comparing basenames across the produce/
# consume boundary is what makes this a composition test rather than a second
# membership test.
# ---------------------------------------------------------------------------

# Join backslash line-continuations so a multi-line invocation is one logical
# line — the recipe wraps `normalize` across three source lines.
r10a1_logical() {
	sed -e ':a' -e '/\\$/{N; s/\\\n[[:space:]]*/ /; ta' -e '}' "$1"
}
# The redirect target of a logical line, unquoted.
r10a1_target() {
	printf '%s\n' "$1" | sed -E 's/.*>[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//'
}
# The last token BEFORE the redirect (the positional), unquoted.
r10a1_positional() {
	printf '%s\n' "$1" | sed -E 's/[[:space:]]*>.*$//' | awk '{print $NF}' | sed -E 's/^"//; s/"$//'
}

r10a1_bad=""
for r10a1_md in "${r9g6_mirrors[@]}"; do
	[[ -f "$r10a1_md" ]] || continue
	r10a1_name="$(basename "$(dirname "$(dirname "$(dirname "$r10a1_md")")")")"

	# The negative control for F1: `gate_run_bounded` writes no *raw.json*, so
	# the token must not appear anywhere in either mirror -- not in a command
	# and not in prose that would teach it back.
	if grep -q 'raw\.json' "$r10a1_md"; then
		r10a1_bad="$r10a1_bad [$r10a1_name: the token 'raw.json' appears, but gate_run_bounded writes only <name>.envelope.json / <name>.tool-out.json]"
	fi

	r10a1_section="$(r10a1_logical "$r10a1_md" |
		awk '/is the gate-output dispatcher/{f=1} f{print} f && /run-gate\.sh status-row/{exit}')"
	if [[ -z "$r10a1_section" ]]; then
		r10a1_bad="$r10a1_bad [$r10a1_name: no run-gate recipe section found]"
		continue
	fi

	r10a1_norm="$(printf '%s\n' "$r10a1_section" | grep -E 'run-gate\.sh normalize ' | head -1 || true)"
	r10a1_rec="$(printf '%s\n' "$r10a1_section" | grep -E 'run-gate\.sh reconcile ' | head -1 || true)"
	r10a1_route="$(printf '%s\n' "$r10a1_section" | grep -E 'run-gate\.sh route ' | head -1 || true)"
	r10a1_jq="$(printf '%s\n' "$r10a1_section" | grep -F "jq -c '.trivial_envelope'" | head -1 || true)"

	# normalize: reads a declared ENVELOPE, writes its own file.
	if [[ "$r10a1_norm" != *".envelope.json"* ]]; then
		r10a1_bad="$r10a1_bad [$r10a1_name: normalize's positional is not a *.envelope.json: '$r10a1_norm']"
	fi
	if [[ "$r10a1_norm" != *">"* ]]; then
		r10a1_bad="$r10a1_bad [$r10a1_name: normalize emits to stdout but its invocation has no '>' redirect -- nothing produces the pooled findings]"
	fi

	# reconcile's OUTPUT must be route's INPUT.
	if [[ "$r10a1_rec" != *">"* ]]; then
		r10a1_bad="$r10a1_bad [$r10a1_name: reconcile emits to stdout but its invocation has no '>' redirect -- reconciled.json has no producer]"
	else
		r10a1_rec_out="$(r10a1_target "$r10a1_rec")"
		r10a1_route_in="$(r10a1_positional "$r10a1_route")"
		if [[ "${r10a1_rec_out##*/}" != "${r10a1_route_in##*/}" ]]; then
			r10a1_bad="$r10a1_bad [$r10a1_name: reconcile writes '${r10a1_rec_out##*/}' but route reads '${r10a1_route_in##*/}']"
		fi
	fi

	# route's OUTPUT must be what the trivial-envelope extraction reads.
	if [[ "$r10a1_route" != *">"* ]]; then
		r10a1_bad="$r10a1_bad [$r10a1_name: route emits to stdout but its invocation has no '>' redirect -- route_output.json has no producer]"
	elif [[ -z "$r10a1_jq" ]]; then
		r10a1_bad="$r10a1_bad [$r10a1_name: no \"jq -c '.trivial_envelope'\" extraction in the recipe section]"
	else
		r10a1_route_out="$(r10a1_target "$r10a1_route")"
		r10a1_jq_in="$(printf '%s\n' "$r10a1_jq" | sed -E "s/.*jq -c '\.trivial_envelope'[[:space:]]*//" | awk '{print $1}' | sed -E 's/^"//; s/"$//')"
		if [[ "${r10a1_route_out##*/}" != "${r10a1_jq_in##*/}" ]]; then
			r10a1_bad="$r10a1_bad [$r10a1_name: route writes '${r10a1_route_out##*/}' but the trivial-envelope extraction reads '${r10a1_jq_in##*/}']"
		fi
	fi
done

if [[ -z "$r10a1_bad" ]]; then
	pass "R10-A1a: in both mirrors the run-gate recipe composes -- normalize reads a declared envelope and redirects, reconcile's output is route's input, and route's output is what the trivial-envelope extraction reads"
else
	fail "R10-A1a:$r10a1_bad"
fi

# ---------------------------------------------------------------------------
# R10-A1b (round 10, F3/F4) — the bullets must be in OPERATIVE order and both
# mirrors must carry the sole-route normative sentence.
#
# R9-G6a enforces "never through a bundled pipeline script a subcommand
# already wraps" against BOTH mirrors, but the sentence that STATES the rule
# landed only in the Claude one — a rule enforced against a mirror that does
# not state it. The Codex mirror also presented `reconcile` before `normalize`
# with a parenthetical conceding that the operative order was the other way
# round, so the reading order contradicted the running order.
# ---------------------------------------------------------------------------
r10a1b_bad=""
for r10a1b_md in "${r9g6_mirrors[@]}"; do
	[[ -f "$r10a1b_md" ]] || continue
	r10a1b_name="$(basename "$(dirname "$(dirname "$(dirname "$r10a1b_md")")")")"

	if ! grep -qE 'Every gate-output step goes through .run-gate\.sh.' "$r10a1b_md"; then
		r10a1b_bad="$r10a1b_bad [$r10a1b_name: missing the sole-route normative sentence R9-G6a enforces against it]"
	fi

	r10a1b_lines=()
	for r10a1b_sub in normalize reconcile route; do
		r10a1b_n="$(grep -nE '("\$\{CLAUDE_PLUGIN_ROOT\}"/skills/review-gauntlet/lib/|"\$SKILL_DIR"/lib/)run-gate\.sh '"$r10a1b_sub"'([[:space:]]|$)' "$r10a1b_md" | head -1 | cut -d: -f1 || true)"
		r10a1b_lines+=("$r10a1b_n")
	done
	if [[ -z "${r10a1b_lines[0]}" || -z "${r10a1b_lines[1]}" || -z "${r10a1b_lines[2]}" ]]; then
		r10a1b_bad="$r10a1b_bad [$r10a1b_name: could not locate all three runnable invocations (got '${r10a1b_lines[*]}')]"
	elif ! ((r10a1b_lines[0] < r10a1b_lines[1] && r10a1b_lines[1] < r10a1b_lines[2])); then
		r10a1b_bad="$r10a1b_bad [$r10a1b_name: bullets are not in operative order normalize(${r10a1b_lines[0]}) < reconcile(${r10a1b_lines[1]}) < route(${r10a1b_lines[2]})]"
	fi
done

if [[ -z "$r10a1b_bad" ]]; then
	pass "R10-A1b: both mirrors present normalize -> reconcile -> route in operative order and carry the sole-route normative sentence"
else
	fail "R10-A1b:$r10a1b_bad"
fi

# ---------------------------------------------------------------------------
# R11-F2 — neither mirror hand-codes the claim join.
#
# The unique-(file,line) claim rule decides what enters the ledger's
# cumulative `fixed_keys`, and an over-claim there fires the TERMINAL
# `regression` stop on a healthy loop. It was ~45 lines of jq authored TWICE
# in prose (once per mirror) and covered by no test. It now lives in
# scripts/claimed-findings.sh with the same ownership contract as
# finding-key.sh. These assertions are what stop it being pasted back in.
r11f2_bad=""
for r11f2_md in "$SKILL_MD" "$CODEX_SKILL_MD"; do
	r11f2_label="$(basename "$(dirname "$(dirname "$(dirname "$r11f2_md")")")")"
	grep -Fq -- '--slurpfile m' "$r11f2_md" &&
		r11f2_bad="$r11f2_bad [$r11f2_label still hand-codes the manifest join (--slurpfile m)]"
	grep -Fq 'group_by((.file|tostring)' "$r11f2_md" &&
		r11f2_bad="$r11f2_bad [$r11f2_label still hand-codes the unique-(file,line) group_by]"
	r11f2_calls="$(grep -c 'claimed-findings\.sh' "$r11f2_md" || true)"
	[[ "$r11f2_calls" == "1" ]] ||
		r11f2_bad="$r11f2_bad [$r11f2_label invokes claimed-findings.sh $r11f2_calls times, expected exactly 1]"
done
if [[ -z "$r11f2_bad" ]]; then
	pass "R11-F2: neither review-gauntlet mirror hand-codes the claim join; both call the bundled claimed-findings.sh exactly once"
else
	fail "R11-F2:$r11f2_bad"
fi

# The bundled script must actually be there to call, in both mirrors.
r11f2_bundle_bad=""
for r11f2_dir in skein skein-codex; do
	[[ -f "$ROOT_DIR/plugins/$r11f2_dir/skills/review-gauntlet/scripts/claimed-findings.sh" ]] ||
		r11f2_bundle_bad="$r11f2_bundle_bad [$r11f2_dir]"
done
if [[ -z "$r11f2_bundle_bad" ]]; then
	pass "R11-F2: claimed-findings.sh is bundled into both review-gauntlet mirrors"
else
	fail "R11-F2: claimed-findings.sh missing from bundle:$r11f2_bundle_bad (is it registered in scripts/lib/bundle-map.sh's bundle_extra_for?)"
fi

# ---------------------------------------------------------------------------
# R11-F8 — the two mirrors differ only by their harness anchor.
#
# Codex declared keys_dir/present_keys_file/claimed_findings_file/
# claimed_keys_file/auto_fix_manifest in the up-front gate-paths block;
# Claude declared them inline at the convergence step. That is a STRUCTURAL
# divergence, and the mirrors' stated invariant is that they diverge only in
# ${CLAUDE_PLUGIN_ROOT} vs $SKILL_DIR. Codex's placement was adopted.
#
# "In the gate-paths block" is checked positionally: each declaration must
# appear before the first status-row invocation, which is the block's
# downstream consumer and sits well after the gate-path declarations.
r11f8_bad=""
for r11f8_md in "$SKILL_MD" "$CODEX_SKILL_MD"; do
	r11f8_label="$(basename "$(dirname "$(dirname "$(dirname "$r11f8_md")")")")"
	r11f8_anchor="$(grep -n 'run-gate\.sh status-row' "$r11f8_md" | head -1 | cut -d: -f1)"
	if [[ -z "$r11f8_anchor" ]]; then
		r11f8_bad="$r11f8_bad [$r11f8_label has no status-row invocation to anchor on]"
		continue
	fi
	for r11f8_var in keys_dir present_keys_file claimed_findings_file claimed_keys_file auto_fix_manifest; do
		r11f8_line="$(grep -n "^${r11f8_var}=" "$r11f8_md" | head -1 | cut -d: -f1)"
		if [[ -z "$r11f8_line" ]]; then
			r11f8_bad="$r11f8_bad [$r11f8_label never declares $r11f8_var]"
		elif [[ "$r11f8_line" -gt "$r11f8_anchor" ]]; then
			r11f8_bad="$r11f8_bad [$r11f8_label declares $r11f8_var at :$r11f8_line, after the gate-paths block]"
		fi
	done
done
if [[ -z "$r11f8_bad" ]]; then
	pass "R11-F8: both gauntlet mirrors declare the key-file variables in the up-front gate-paths block"
else
	fail "R11-F8:$r11f8_bad"
fi

# ---------------------------------------------------------------------------
# R11-F21 — the injection-mitigation section names DERIVED content.
#
# Old invariant: untrusted <=> plan/diff content. But gate-produced finding
# text is derived from reviewed code and reaches the EDIT-CAPABLE fixer, so a
# crafted comment can steer a gate into emitting a `suggestion` that reads as
# an instruction. New invariant: untrusted <=> anything derived from reviewed
# content, gate findings and fixer-report text included.
r11f21_bad=""
for r11f21_md in "$SKILL_MD" "$CODEX_SKILL_MD"; do
	r11f21_label="$(basename "$(dirname "$(dirname "$(dirname "$r11f21_md")")")")"
	grep -Fq 'fixer-report.json' "$r11f21_md" ||
		r11f21_bad="$r11f21_bad [$r11f21_label never mentions fixer-report.json]"
	grep -Eq 'gate-produced finding' "$r11f21_md" ||
		r11f21_bad="$r11f21_bad [$r11f21_label does not name gate-produced finding fields as untrusted]"
	grep -Eq '`suggestion`' "$r11f21_md" ||
		r11f21_bad="$r11f21_bad [$r11f21_label does not name the suggestion field]"
done
if [[ -z "$r11f21_bad" ]]; then
	pass "R11-F21: both mirrors' injection-mitigation section names gate findings and fixer-report content as untrusted"
else
	fail "R11-F21:$r11f21_bad"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
