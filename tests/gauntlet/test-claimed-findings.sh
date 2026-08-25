#!/usr/bin/env bash
# test-claimed-findings.sh — runtime acceptance for scripts/claimed-findings.sh,
# the round-11 extraction of what used to be ~45 lines of jq authored twice in
# SKILL.md prose (once per mirror) and covered by nothing.
#
# The subject is the unique-(file, line) CLAIM RULE and the both-sources-optional
# contract. Getting the claim rule wrong is not a cosmetic failure: an
# over-claimed finding is promoted into the ledger's cumulative `fixed_keys`,
# and its legitimate reappearance then fires the TERMINAL `regression` stop,
# halting a healthy convergence loop. Case (b) is that guard.
#
# Case (f) is the one that would have caught the original hazard: a `.findings:
# null` envelope makes the unconditional `.findings[]` form exit 5, and under
# the caller's `pipefail` that aborts the round before a single key file is
# written -- on exactly the clean round that should have succeeded.
#
# Exit codes: 0 all assertions pass, 1 any assertion fails.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SCRIPT="$ROOT_DIR/scripts/claimed-findings.sh"

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
	local actual="$1" expected="$2" label="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

if [[ ! -x "$SCRIPT" ]]; then
	fail "claimed-findings.sh missing or not executable: $SCRIPT"
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	fail "jq is required to run this test"
	echo "Results: $pass_count passed, $fail_count failed"
	exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- (a) a unique (file, line) whose manifest entry is `applied` is claimed --

env_a="$WORKDIR/env-a.json"
cat >"$env_a" <<'EOF'
{"findings": [
  {"file": "a.py", "line": 10, "category": "correctness", "summary": "off-by-one"},
  {"file": "b.py", "line": 20, "category": "style", "summary": "typo"}
]}
EOF
man_a="$WORKDIR/man-a.json"
cat >"$man_a" <<'EOF'
[{"kind": "docstring_typo", "file": "a.py", "line": 10, "status": "applied"}]
EOF
out_a="$WORKDIR/out-a.jsonl"
rc_a=0
"$SCRIPT" --envelope "$env_a" --manifest "$man_a" >"$out_a" 2>/dev/null || rc_a=$?
assert_eq "$rc_a" "0" "(a) an applied manifest entry against a unique (file,line) exits 0"
assert_eq "$(grep -c '^' "$out_a")" "1" "(a) ...emitting exactly one claim"
assert_eq "$(jq -r '.summary' "$out_a")" "off-by-one" \
	"(a) ...the ENVELOPE's finding, joined back on (file,line) to recover category/summary the manifest never carries"

# --- (b) two findings sharing one (file, line) are BOTH dropped -------------
# The manifest's `kind` is an auto-fix kind, not a review category, so there is
# nothing to disambiguate the pair with. Under-claim (lose one key, it is
# re-reported next round) rather than over-claim (promote a finding nobody
# fixed into fixed_keys, then terminally `regression`-stop on its legitimate
# reappearance).

env_b="$WORKDIR/env-b.json"
cat >"$env_b" <<'EOF'
{"findings": [
  {"file": "a.py", "line": 10, "category": "correctness", "summary": "off-by-one"},
  {"file": "a.py", "line": 10, "category": "security", "summary": "unsanitised input"},
  {"file": "c.py", "line": 5, "category": "style", "summary": "solo"}
]}
EOF
man_b="$WORKDIR/man-b.json"
cat >"$man_b" <<'EOF'
[{"kind": "docstring_typo", "file": "a.py", "line": 10, "status": "applied"},
 {"kind": "docstring_typo", "file": "c.py", "line": 5, "status": "applied"}]
EOF
out_b="$WORKDIR/out-b.jsonl"
rc_b=0
"$SCRIPT" --envelope "$env_b" --manifest "$man_b" >"$out_b" 2>/dev/null || rc_b=$?
assert_eq "$rc_b" "0" "(b) an ambiguous (file,line) is not an error"
assert_eq "$(jq -sr 'map(.file) | join(",")' "$out_b")" "c.py" \
	"(b) two findings sharing one (file,line) are BOTH dropped; the unambiguous sibling is still claimed"

# --- (c) a manifest entry whose status is not `applied` is not claimed ------

env_c="$env_a"
man_c="$WORKDIR/man-c.json"
cat >"$man_c" <<'EOF'
[{"kind": "docstring_typo", "file": "a.py", "line": 10, "status": "skipped"},
 {"kind": "docstring_typo", "file": "b.py", "line": 20, "status": "failed"}]
EOF
out_c="$WORKDIR/out-c.jsonl"
rc_c=0
"$SCRIPT" --envelope "$env_c" --manifest "$man_c" >"$out_c" 2>/dev/null || rc_c=$?
assert_eq "$rc_c" "0" "(c) a manifest with no applied entries exits 0"
assert_eq "$(grep -c '^' "$out_c" || true)" "0" \
	"(c) ...and claims nothing (status != applied is not a fix)"

# --- (d) no --manifest flag: fixer claims only ------------------------------

fixer_d="$WORKDIR/fixer-d.json"
cat >"$fixer_d" <<'EOF'
{"claimed": [
  {"file": "z.py", "line": 1, "category": "correctness", "summary": "fixed by fixer"}
]}
EOF
out_d="$WORKDIR/out-d.jsonl"
rc_d=0
"$SCRIPT" --envelope "$env_a" --fixer-report "$fixer_d" >"$out_d" 2>/dev/null || rc_d=$?
assert_eq "$rc_d" "0" "(d) omitting --manifest exits 0"
assert_eq "$(jq -sr 'map(.summary) | join(",")' "$out_d")" "fixed by fixer" \
	"(d) ...and contributes the fixer's claims only"

# ORDER: applier-owned first, then fixer-owned, when both are present.
out_d2="$WORKDIR/out-d2.jsonl"
"$SCRIPT" --envelope "$env_a" --manifest "$man_a" --fixer-report "$fixer_d" >"$out_d2" 2>/dev/null
assert_eq "$(jq -sr 'map(.file) | join(",")' "$out_d2")" "a.py,z.py" \
	"(d) with both sources, applier-owned claims precede fixer-owned ones"

# --- (e) no claim source at all: exit 0, empty stdout -----------------------
# THE load-bearing case. A clean round runs no fixer and applies no auto-fix;
# an empty result is the correct answer, not an error.

out_e="$WORKDIR/out-e.jsonl"
rc_e=0
"$SCRIPT" --envelope "$env_a" >"$out_e" 2>/dev/null || rc_e=$?
assert_eq "$rc_e" "0" "(e) no claim source at all exits 0 (a clean round is not a failure)"
assert_eq "$(grep -c '^' "$out_e" || true)" "0" "(e) ...with empty stdout"

# A named-but-ZERO-BYTE source is the artifact existing and holding nothing --
# also legitimate, distinct from a named-but-missing one (see (g2)).
empty_man="$WORKDIR/empty-manifest.json"
: >"$empty_man"
empty_fixer="$WORKDIR/empty-fixer.json"
: >"$empty_fixer"
out_e2="$WORKDIR/out-e2.jsonl"
rc_e2=0
"$SCRIPT" --envelope "$env_a" --manifest "$empty_man" --fixer-report "$empty_fixer" \
	>"$out_e2" 2>/dev/null || rc_e2=$?
assert_eq "$rc_e2" "0" "(e) a named but zero-byte manifest/fixer-report exits 0"
assert_eq "$(grep -c '^' "$out_e2" || true)" "0" "(e) ...with empty stdout"

# --- (f) envelope with `.findings: null` -----------------------------------
# The pipefail regression this extraction replaces: `.findings[]` (no `?`)
# exits 5 on a null field, aborting the round under the caller's pipefail.

env_f="$WORKDIR/env-f.json"
printf '{"findings": null}\n' >"$env_f"
out_f="$WORKDIR/out-f.jsonl"
rc_f=0
"$SCRIPT" --envelope "$env_f" --manifest "$man_a" >"$out_f" 2>/dev/null || rc_f=$?
assert_eq "$rc_f" "0" "(f) an envelope with .findings:null exits 0, not 5 (the pipefail regression)"
assert_eq "$(grep -c '^' "$out_f" || true)" "0" "(f) ...with empty stdout"

env_f2="$WORKDIR/env-f2.json"
printf '{}\n' >"$env_f2"
rc_f2=0
"$SCRIPT" --envelope "$env_f2" --manifest "$man_a" >/dev/null 2>&1 || rc_f2=$?
assert_eq "$rc_f2" "0" "(f) an envelope with NO .findings key at all also exits 0"

fixer_f="$WORKDIR/fixer-f.json"
printf '{"claimed": null}\n' >"$fixer_f"
rc_f3=0
"$SCRIPT" --envelope "$env_a" --fixer-report "$fixer_f" >/dev/null 2>&1 || rc_f3=$?
assert_eq "$rc_f3" "0" "(f) a fixer report with .claimed:null also exits 0 (both extractions are total)"

man_f="$WORKDIR/man-f.json"
printf 'null\n' >"$man_f"
rc_f4=0
"$SCRIPT" --envelope "$env_a" --manifest "$man_f" >/dev/null 2>&1 || rc_f4=$?
assert_eq "$rc_f4" "0" "(f) a manifest whose document is literal null also exits 0 (\$m[0] // [])"

# --- (g) usage errors -------------------------------------------------------

rc_g=0
"$SCRIPT" --envelope "$env_a" --bogus x >/dev/null 2>&1 || rc_g=$?
assert_eq "$rc_g" "2" "(g) an unknown flag exits 2"

rc_g2=0
"$SCRIPT" >/dev/null 2>&1 || rc_g2=$?
assert_eq "$rc_g2" "2" "(g) a missing --envelope exits 2"

rc_g3=0
"$SCRIPT" --envelope "$WORKDIR/does-not-exist.json" >/dev/null 2>&1 || rc_g3=$?
assert_eq "$rc_g3" "2" "(g) an unreadable --envelope exits 2"

# A NAMED source that cannot be read is a wiring bug (exit 2). This is the
# distinction the both-sources-optional contract turns on: "the caller decided
# there was no manifest" and "the caller pointed at a manifest that isn't
# there" are different facts and must not share an outcome.
rc_g4=0
"$SCRIPT" --envelope "$env_a" --manifest "$WORKDIR/no-such-manifest.json" >/dev/null 2>&1 || rc_g4=$?
assert_eq "$rc_g4" "2" "(g) a NAMED but missing --manifest exits 2, unlike an omitted one"

rc_g5=0
"$SCRIPT" --envelope "$env_a" --manifest >/dev/null 2>&1 || rc_g5=$?
assert_eq "$rc_g5" "2" "(g) a flag given without its value exits 2"

# --- (h) malformed JSON exits 3, distinctly from a usage error --------------

bad_env="$WORKDIR/bad-env.json"
printf 'not json at all\n' >"$bad_env"
rc_h=0
"$SCRIPT" --envelope "$bad_env" >/dev/null 2>&1 || rc_h=$?
assert_eq "$rc_h" "3" "(h) a malformed envelope exits 3, not 2"

bad_man="$WORKDIR/bad-man.json"
printf '{oops\n' >"$bad_man"
rc_h2=0
"$SCRIPT" --envelope "$env_a" --manifest "$bad_man" >/dev/null 2>&1 || rc_h2=$?
assert_eq "$rc_h2" "3" "(h) a malformed manifest exits 3"

# --- (i) the bundled mirrors are byte-identical to the canonical script -----

for mirror in plugins/skein plugins/skein-codex; do
	bundled="$ROOT_DIR/$mirror/skills/review-gauntlet/scripts/claimed-findings.sh"
	if [[ -f "$bundled" ]] && cmp -s "$SCRIPT" "$bundled"; then
		pass "(i) $mirror's bundled claimed-findings.sh is byte-identical to scripts/"
	else
		fail "(i) $mirror's bundled claimed-findings.sh is missing or has drifted from scripts/"
	fi
done

# --- (j) the output feeds finding-key.sh unchanged --------------------------
# The consumer is `claimed-findings.sh ... | finding-key.sh - | sort -u`, so
# every emitted object must be a single-line JSON object finding-key.sh can key.

keys_out="$WORKDIR/keys.txt"
if "$SCRIPT" --envelope "$env_a" --manifest "$man_a" --fixer-report "$fixer_d" |
	"$ROOT_DIR/scripts/finding-key.sh" - >"$keys_out" 2>/dev/null; then
	assert_eq "$(grep -c '^' "$keys_out")" "2" \
		"(j) the emitted JSONL feeds finding-key.sh directly, one key per claim"
else
	fail "(j) finding-key.sh could not consume claimed-findings.sh's output"
fi

echo ""
echo "Results: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
