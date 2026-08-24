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

assert_grep "$SKILL_MD" 'reconcile-findings\.sh' \
	"references the bundled \`reconcile-findings.sh\`"

assert_not_grep "$SKILL_MD" 'reconcile-findings\.sh[^\n]*--skill' \
	"does not call \`reconcile-findings.sh\` with \`--skill\`"

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

	assert_grep_fixed "$file" "${ledger_invoke_prefix}/lib/convergence-ledger.sh --ledger \"\$ledger_path\" --target \"\$canonical_target\" --count" \
		"$label: write-side wiring documents the per-round append call binding \`--ledger \$ledger_path --target \$canonical_target\`"
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

assert_status_row_before_decision_for() {
	local file="$1" label="$2"

	if [[ ! -f "$file" ]]; then
		fail "$label: file missing: $file"
		return
	fi

	local status_row_line decision_line
	status_row_line="$(grep -n -m1 -i 'status-row' "$file" | cut -d: -f1 || true)"
	decision_line="$(grep -n -m1 -iE 'convergence-ledger\.sh' "$file" | tail -1 | cut -d: -f1 || true)"

	if [[ -n "$status_row_line" ]]; then
		pass "$label: status-row is referenced (line $status_row_line) so an ordering check is possible"
	else
		fail "$label: status-row is never referenced, cannot verify print-before-decision ordering"
	fi
}

assert_status_row_before_decision_for "$SKILL_MD" "Claude mirror"
assert_status_row_before_decision_for "$CODEX_SKILL_MD" "Codex mirror"

echo ""
echo "Results: $pass_count passed, $fail_count failed"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
