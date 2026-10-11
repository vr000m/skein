#!/usr/bin/env bash
# Static acceptance checks for Codex's opt-in HTML report integration.
# Runtime renderer and hook behaviour is covered by test-render-report.sh.
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
GAUNTLET="$ROOT_DIR/plugins/skein-codex/skills/review-gauntlet/SKILL.md"
DEEP="$ROOT_DIR/plugins/skein-codex/skills/deep-review/SKILL.md"

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
assert_eq() {
	if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}
count_fixed() { { grep -cF -- "$2" "$1" || true; }; }
count_re() { { grep -cE -- "$2" "$1" || true; }; }
has() {
	if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}
lacks_re() {
	if grep -qE -- "$2" "$1"; then fail "$3 (matched /$2/)"; else pass "$3"; fi
}
line_of() {
	local n
	n="$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1 || true)"
	printf '%s' "${n:-0}"
}

for f in "$GAUNTLET" "$DEEP"; do
	if [[ ! -f "$f" ]]; then
		echo "FAIL: missing $f"
		exit 1
	fi
done

echo '== review-gauntlet: flag gating and default output =='
assert_eq "$(sed -n '1,8p' "$GAUNTLET" | grep -c 'argument-hint:.*--report' || true)" 1 'argument-hint lists --report'
# shellcheck disable=SC2016
has "$GAUNTLET" '`--report` is a rendering-mode modifier' '--report is a rendering-mode modifier'
# shellcheck disable=SC2016
# shellcheck disable=SC2016
has "$GAUNTLET" 'Without `--report`, do nothing and preserve the existing text output.' 'default gauntlet output is unchanged and no hook runs'

echo '== review-gauntlet: terminal, resume and error paths =='
# shellcheck disable=SC2016
has "$GAUNTLET" '### Terminal report step (`--report` only)' 'report step exists only for opted-in terminal outcomes'
has "$GAUNTLET" 'after any terminal ledger decision' 'terminal ledger outcomes route through report step'
# shellcheck disable=SC2016
has "$GAUNTLET" 'a `--resume`/auto-chain peek that returns exit 5' 'terminal resume paths route through report step'
has "$GAUNTLET" 'A non-terminal round does not' 'non-terminal rounds skip report step'
has "$GAUNTLET" 'The hook always exits 0' 'hook failure cannot change gauntlet outcome'
has "$GAUNTLET" 'renderer failure cannot change the terminal token, ledger, normal output, or exit status' 'report failures preserve terminal token and exit status'
has "$GAUNTLET" 'any other non-zero exit' 'non-terminal resume errors stop before gates'
# shellcheck disable=SC2016
has "$GAUNTLET" 'success_with_quarantine`, `regression`, `cap`, or `non-converge' 'terminal token classes include convergence outcomes'

echo '== review-gauntlet: run_dir lifecycle =='
# shellcheck disable=SC2016
assert_eq "$(count_re "$GAUNTLET" '^run_dir="\$\(.*convergence-ledger\.sh --run-dir --ledger "\$ledger_path"\)"$')" 1 'run_dir comes from one --run-dir call'
assert_eq "$(count_re "$GAUNTLET" '^[[:space:]]*run_dir=')" 1 'run_dir is assigned once'
# shellcheck disable=SC2016
has "$GAUNTLET" 'gate_out_dir="$run_dir/round-$round_n"' 'round gate output derives from run_dir'
# shellcheck disable=SC2016
has "$GAUNTLET" 'round_n="$(( $(jq -r '\''.rounds | length'\'' "$ledger_path") + 1 ))"' 'resume derives round number from ledger'
has "$GAUNTLET" '--init --force' 'fresh run clears prior run directory through guarded init'
has "$GAUNTLET" 'never re-initialize' 'resume preserves existing run directory'
has "$GAUNTLET" 'it is idempotent and never clears the directory' 'run-dir creation is idempotent'
# shellcheck disable=SC2016
lacks_re "$GAUNTLET" 'rm -rf[^`]*run_dir|rm -rf[^`]*ledger-stem' 'skill prose does not directly remove run_dir'

echo '== review-gauntlet: Codex dispatch and deferred gate =='
# shellcheck disable=SC2016
assert_eq "$(count_re "$GAUNTLET" '^[[:space:]]*"\$SKILL_DIR"/scripts/report-hook\.sh')" 1 'one report hook call uses Codex SKILL_DIR anchor'
# shellcheck disable=SC2016
has "$GAUNTLET" '--root "$REPO_ROOT" --out "$report_out"' 'hook receives report output'
# shellcheck disable=SC2016
has "$GAUNTLET" 'report_args=(--ledger "$ledger_path")' 'hook receives ledger through argument array'
# shellcheck disable=SC2016
has "$GAUNTLET" 'report_args+=(--round "$n=$envelope")' 'hook receives existing round envelopes'
# shellcheck disable=SC2016
has "$GAUNTLET" 'jq -r '\''.rounds | length'\'' "$ledger_path"' 'round enumeration comes from ledger'
has "$GAUNTLET" 'The hook always exits 0' 'hook failure cannot change terminal result'
# shellcheck disable=SC2016
has "$GAUNTLET" 'Never pass `--report`' 'deferred deep-review slot excludes report flag'
lacks_re "$GAUNTLET" 'skein:deep-review( --verbose)? --report|skein:deep-review --report' 'deep-review gate invocation never carries --report'
# shellcheck disable=SC2016
lacks_re "$GAUNTLET" 'skein:deep-review[^`]*`--report`[^.]*(pass|forward|append)' 'orchestrator never forwards report flag to deep-review slot'
lacks_re "$GAUNTLET" '\$\{CLAUDE_PLUGIN_ROOT\}' 'Codex gauntlet uses no Claude path anchor'

echo '== deep-review: flag gating and default output =='
assert_eq "$(sed -n '1,8p' "$DEEP" | grep -c 'argument-hint:.*--report' || true)" 1 'argument-hint lists --report'
# shellcheck disable=SC2016
has "$DEEP" '`--report` is also a rendering-mode modifier' '--report does not change review input'
has "$DEEP" 'Without the flag, output and scratch-file behavior stay unchanged.' 'default deep-review output and scratch behavior are unchanged'
# shellcheck disable=SC2016
has "$DEEP" '**With `--report` only:**' 'envelope capture is flag-gated'
# shellcheck disable=SC2016
has "$DEEP" 'report_envelope="$(mktemp "${TMPDIR:-/tmp}/skein-report-envelope.XXXXXX")"' 'audited envelope is captured in scratch file'
# shellcheck disable=SC2016
has "$DEEP" 'audit-auto-fix-eligibility.sh --skill deep-review <envelope> > "$report_envelope"' 'audit envelope stdout is redirected to scratch file'

echo '== deep-review: suppression and applied-fix keys =='
# shellcheck disable=SC2016
has "$DEEP" 'report_keys="$(mktemp "${TMPDIR:-/tmp}/skein-report-keys.XXXXXX")"' 'suppression keys use scratch file'
has "$DEEP" 'status == "applied"' 'applied auto-fix entries are selected'
# shellcheck disable=SC2016
has "$DEEP" '.file == $m.file' 'applied entries join to envelope findings by file'
# shellcheck disable=SC2016
has "$DEEP" '(.line | tostring) == ($m.line | tostring)' 'applied entries join to envelope findings by line'
has "$DEEP" 'has("auto_fix")' 'applied entries join only auto-fix candidates'
has "$DEEP" 'join("\t")' 'applied and suppressed keys serialize as tab-separated tuples'
has "$DEEP" 'report_envelope' 'applied keys are joined against captured envelope'
# shellcheck disable=SC2016
has "$DEEP" 'retain the `(file, line, category)` tuple for every finding suppressed here' 'suppressed findings retain exact tuple keys'
# shellcheck disable=SC2016
has "$DEEP" 'line field for null, absent, or `-1` lines' 'suppression tuples normalize absent line values'
has "$DEEP" 'Step 5.5 writes these tuples alongside applied auto-fix tuples to the scratch suppress-keys file.' 'suppressed keys are written beside applied keys'
has "$DEEP" 'if .line == null or .line == -1 then ""' 'applied key tuples normalize null and sentinel lines'
# shellcheck disable=SC2016
has "$DEEP" 'The renderer filters only exact `(file, line, category)` matches.' 'report suppression filters exact tuple matches'
has "$DEEP" 'suppressed and applied-auto-fixed findings omitted' 'report documents suppressed and applied findings'
# shellcheck disable=SC2016
has "$DEEP" '--envelope "$report_envelope" --suppress-keys "$report_keys"' 'hook receives envelope and suppress keys'
# shellcheck disable=SC2016
assert_eq "$(count_re "$DEEP" '^[[:space:]]*"\$SKILL_DIR"/scripts/report-hook\.sh')" 1 'one deep-review hook invocation uses Codex anchor'
# shellcheck disable=SC2016
assert_eq "$(count_fixed "$DEEP" 'rm -f "$report_envelope" "$report_keys"')" 1 'both scratch files are removed'
has "$DEEP" 'regardless of success' 'scratch cleanup covers hook success and failure'
has "$DEEP" 'If the hook is absent, print a warning and run the same cleanup command.' 'warning path also cleans scratch files'
# shellcheck disable=SC2016
has "$DEEP" '--out "$REPO_ROOT/.deep-review/report-codex.html"' 'Codex report has its own latest-run path'
lacks_re "$DEEP" '\$\{CLAUDE_PLUGIN_ROOT\}' 'Codex deep-review uses no Claude path anchor'

echo
echo "Results: $pass_count passed, $fail_count failed"
if [[ "$fail_count" -gt 0 ]]; then exit 1; fi
