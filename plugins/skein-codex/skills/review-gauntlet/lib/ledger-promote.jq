# ledger-promote.jq — the convergence ledger's round-append filter, including
# the cross-round pending_claims/fixed_keys promotion state machine.
#
# Invoked ONLY from convergence-ledger.sh's append path as
#
#   jq -f "$SCRIPT_DIR/ledger-promote.jq" \
#      --argjson count --argjson structural --argjson local \
#      --arg pass_type --argjson quarantine --argjson unresolved \
#      --argjson cap --argjson k \
#      --argjson present_keys --argjson claimed_keys \
#      --argjson keys_active --argjson present_supplied \
#      "$LEDGER_PATH" > <temp>
#
# and it is a pure function of {ledger on stdin-file, those twelve args}. It
# reads no files, shells out to nothing, and has no side effects; the caller
# owns the temp-file + atomic-rename write.
#
# WHY IT IS A FILE (r11/F9). It used to be a single-quoted jq program embedded
# in that `jq` call, which forced every apostrophe in its prose through the
# shell as '"'"' and made the comments below unreadable at exactly the point
# where the logic is hardest. It is the most safety-critical filter in the
# ledger — it decides what counts as PROVEN FIXED — so the comments are the
# artefact worth protecting. Extracting it changes NO behaviour: the filter
# text is character-for-character the same jq program modulo the un-escaped
# apostrophes and comment reflow, and the arguments are identical.
#
# EVERY ARGUMENT IS REQUIRED. jq fails on an undefined $variable, so a caller
# that drops one gets a hard error rather than a silently different ledger.

.loop_counter += 1

# cap/k are backfilled, never overwritten: a ledger that already persisted
# them was created with those values and they stay authoritative over
# whatever --cap/--k this invocation happens to carry.
| (if has("cap") then . else .cap = $cap end)
| (if has("k") then . else .k = $k end)

# keys_active gates EVERY bit of the regression-key machinery below,
# including whether a round even GAINS a `present_keys`/`claimed_keys`
# field: a ledger that has never once seen --present-keys/--claimed-keys
# (this round OR any prior round already on disk) must come out of this
# append byte-for-byte identical to the pre-Phase-3 shape — no
# `fixed_keys`, no `pending_claims`, no `present_keys` anywhere. The caller
# computes keys_active; this filter only obeys it.
| (if $keys_active then
     (if has("fixed_keys") then . else .fixed_keys = [] end)
     | (if has("pending_claims") then . else .pending_claims = [] end)

     # Step 2 — EVALUATE pending claims, only on a COMPLETE FULL PASS WITH
     # EVIDENCE (pass_type == full AND unresolved == 0 AND
     # present_supplied). A pending claim absent from THIS round's
     # present_keys is proven fixed and promoted into the cumulative
     # fixed_keys set; every pending claim (promoted or not) is then
     # cleared — a still-present claim is DROPPED, never promoted, and
     # never retried automatically (the fixer must claim it again on some
     # later round that actually shows it gone). A confirm pass, a degraded
     # full pass (unresolved > 0), or a full pass that itself omits
     # --present-keys neither promotes nor drops — pending_claims is left
     # exactly as it was.
     | (if ($pass_type == "full" and $unresolved == 0 and $present_supplied) then
          (.pending_claims - $present_keys) as $promoted
          | .fixed_keys = ((.fixed_keys + $promoted) | unique)
          | .pending_claims = []
        else . end)

     # Step 3 — RECORD this round's claims, strictly AFTER step 2
     # evaluated, so a claim made this round can never be evaluated by the
     # round that made it. Anything already in fixed_keys (post-step-2) is
     # not re-added as a pending claim.
     | .pending_claims = ((.pending_claims + ($claimed_keys - .fixed_keys)) | unique)
   else . end)

# The round itself. Two shapes, selected by the same keys_active gate: with
# key tracking the round carries present_keys/claimed_keys, without it the
# round is exactly the pre-Phase-3 six-field object.
| .rounds += [
    (if $keys_active then
       {
         count: $count,
         structural_tally: $structural,
         local_tally: $local,
         pass_type: $pass_type,
         quarantine_size: $quarantine,
         unresolved_gates: $unresolved,
         present_keys: $present_keys,
         claimed_keys: $claimed_keys
       }
     else
       {
         count: $count,
         structural_tally: $structural,
         local_tally: $local,
         pass_type: $pass_type,
         quarantine_size: $quarantine,
         unresolved_gates: $unresolved
       }
     end)
  ]
