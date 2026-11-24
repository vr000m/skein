"""Phase 3 readiness tests for Pi review-gauntlet capability semantics."""

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / "plugins/skein-pi/lib"))

import pi_ledger
import pytest
import review_gauntlet


def test_stable_absence_is_cached_and_emitted_as_skipped(tmp_path):
    cache = tmp_path / ".review-plan" / "capabilities.json"
    calls = []

    def missing():
        calls.append(1)
        return False, "gate_not_installed"

    first = review_gauntlet.probe(
        "security-review", fingerprint="fp", cache_path=cache, discover=missing
    )
    second = review_gauntlet.probe(
        "security-review", fingerprint="fp", cache_path=cache, discover=missing
    )
    assert first.status == second.status == "unavailable"
    assert second.cached is True
    assert len(calls) == 1
    result = review_gauntlet.coverage([second])
    assert result.outcomes[0].status == "skipped"
    assert not result.clean_full_coverage


def test_transient_probe_failure_is_not_cached(tmp_path):
    cache = tmp_path / "capabilities.json"
    calls = []

    def timeout():
        calls.append(1)
        return False, "timeout"

    first = review_gauntlet.probe(
        "deep-review", fingerprint="fp", cache_path=cache, discover=timeout
    )
    second = review_gauntlet.probe(
        "deep-review", fingerprint="fp", cache_path=cache, discover=timeout
    )
    assert first.status == second.status == "error"
    assert len(calls) == 2
    assert not cache.exists()


def test_zero_runnable_gates_stops_before_convergence(tmp_path):
    cache = tmp_path / "capabilities.json"
    caps = [
        review_gauntlet.probe(
            name,
            fingerprint="fp",
            cache_path=cache,
            discover=lambda: (False, "executable_missing"),
        )
        for name in ("adversarial", "deep-review", "security-review")
    ]
    result = review_gauntlet.coverage(caps)
    assert result.runnable == 0
    assert review_gauntlet.zero_runnable_stop(result) == "zero_runnable_gates"
    assert all(item.status == "skipped" for item in result.outcomes)


def test_refresh_reprobes_cached_absence(tmp_path):
    cache = tmp_path / "capabilities.json"
    calls = []

    def missing():
        calls.append(1)
        return False, "skill_not_registered"

    review_gauntlet.probe("gate", fingerprint="fp", cache_path=cache, discover=missing)
    refreshed = review_gauntlet.probe(
        "gate", fingerprint="fp", cache_path=cache, discover=missing, refresh=True
    )
    assert refreshed.cached is False
    assert len(calls) == 2


def test_fixer_route_is_pi_native_and_rejects_auto_fix():
    request = review_gauntlet.fixer_request(
        [{"file": "x.py", "line": 3, "category": "Logic"}]
    )
    assert set(request) == {"role", "prompt"}
    assert request["role"] == "mechanical"
    policy, payload = request["prompt"].split("INPUT=", 1)
    assert json.loads(payload)["constraints"]["require_regression_test"] is True
    for phrase in (
        "Comment only a non-obvious why",
        "comment that restates the code",
        "comment that excuses a hack: fix the hack, or report it",
        "docstrings, linter and type pragmas, license headers",
        "a full issue URL or `#N`",
        "tautology or stale",
        "inside a hunk or function the change already touches",
        "within the fix's blast radius",
        "never sweep untouched code or widen a fix beyond its finding",
        "Never delete an excuse comment silently",
        "Repair the underlying hack, remove the excuse comment in the same change",
        "claim the finding in claimed",
        "otherwise report it as an Excuse: <file:line> notice in summary",
        "(the repair makes it stale)",
        "when it names an `Excuse:` Documentation finding above Minor in this batch",
        "Copy each claimed finding's file, line, category and summary",
        "excludes it from later fixer batches",
        "cross-file or long-lived decision stays in place",
        "Decision candidate: <file:line> <why>",
        "never a claim or a design delta",
        "the repository's required validation command",
        "main session executes the validation after approved edits",
        "every dispatch and retry",
        "Do not dispatch workers, write files",
    ):
        assert phrase in policy, phrase
    assert "just ci" not in request["prompt"]
    assert '"no_nested_dispatch": true' in request["prompt"]
    assert '"kind": "review-gauntlet-fixer"' in request["prompt"]
    try:
        review_gauntlet.fixer_request([{"auto_fix": {}}])
    except ValueError as error:
        assert "auto_fix" in str(error)
    else:
        raise AssertionError("auto-fix proposal was accepted by Pi route")


def documentation_finding(summary="Decision candidate: chose a bound", **overrides):
    return {
        "file": "x.py",
        "line": 3,
        "category": "Documentation",
        "severity": "suggestion",
        "summary": summary,
        **overrides,
    }


def test_advice_projection_splits_before_same_line_reconciliation():
    candidate = documentation_finding()
    excuse = documentation_finding("temporary hack", severity="important")
    malformed = documentation_finding("decision candidate: chose a bound")
    wrong_severity = documentation_finding(severity="important")
    wrong_category = documentation_finding(category="Logic")
    raw = {
        "gate": "deep-review",
        "status": "findings",
        "findings": [candidate, excuse, malformed, wrong_severity, wrong_category],
        "duration": 2,
    }
    original = json.loads(json.dumps(raw))
    result = review_gauntlet.project_gate_findings(raw)
    assert raw == original
    assert result["advice"] == [candidate]
    assert "near_misses" not in result
    assert result["advice_count"] == 1
    assert result["findings_count"] == 4
    assert result["gate"] == {
        **raw,
        "findings": [excuse, malformed, wrong_severity, wrong_category],
        "findings_count": 4,
    }
    batch = result["gate"]["findings"]
    payload = json.loads(
        review_gauntlet.fixer_request(batch)["prompt"].split("INPUT=")[1]
    )
    assert payload["findings"] == batch
    assert candidate not in batch
    pi_ledger.PiLedger._validate_round(
        {"status": "continue", "gates": [result["gate"]], "findings_count": 4}
    )


@pytest.mark.parametrize(
    ("gate_status", "decision"),
    [("findings", "success"), ("skipped", "partial"), ("degraded", "degraded")],
)
def test_advice_only_projects_ledger_without_upgrading_coverage(
    tmp_path, gate_status, decision
):
    raw = {
        "gate": "deep-review",
        "status": gate_status,
        "reason": "partial coverage" if gate_status != "findings" else None,
        "findings": [documentation_finding()],
        "findings_count": 1,
    }
    result = review_gauntlet.project_gate_findings(raw)
    projected = result["gate"]
    assert result["advice"] == raw["findings"]
    assert result["findings_count"] == projected["findings_count"] == 0
    assert projected["findings"] == []
    assert projected["reason"] == raw["reason"]
    assert projected["status"] == (
        "passed" if gate_status == "findings" else gate_status
    )
    ledger = pi_ledger.PiLedger(tmp_path / "run.json", "target")
    assert (
        ledger.append({"status": decision, "gates": [projected], "findings_count": 0})
        == decision
    )
    assert ledger.read()["rounds"][0]["findings_count"] == 0
    assert raw["findings_count"] == 1
    with pytest.raises(ValueError, match="at least one finding"):
        review_gauntlet.fixer_request(projected["findings"])


@pytest.mark.parametrize(
    "raw",
    [{"status": "unknown"}, {"status": "findings", "findings": [None]}],
)
def test_advice_projection_rejects_malformed_gate(raw):
    with pytest.raises(ValueError):
        review_gauntlet.project_gate_findings(raw)


@pytest.mark.parametrize(
    "raw",
    [
        {"gate": "deep-review", "status": "findings", "findings": []},
        {"gate": "deep-review", "status": "findings"},
    ],
)
def test_empty_findings_envelope_never_projects_to_a_pass(tmp_path, raw):
    projected = review_gauntlet.project_gate_findings(raw)["gate"]
    assert projected["status"] == "findings"
    ledger = pi_ledger.PiLedger(tmp_path / "run.json", "target")
    with pytest.raises(ValueError, match="findings gate has no findings"):
        ledger.append({"status": "success", "gates": [projected], "findings_count": 0})


def test_gauntlet_routes_projection_to_actionable_only_ledger_and_report():
    text = " ".join(
        (Path(__file__).parents[2] / "plugins/skein-pi/skills/review-gauntlet/SKILL.md")
        .read_text()
        .split()
    )
    for phrase in (
        "Before reconciliation, call `project_gate_findings(raw_gate)`",
        (
            "raw per-lens findings (the collector's `--findings-jsonl` stream), "
            "not its structurally reconciled report"
        ),
        (
            "exact `Decision candidate:` summary prefix AND severity Minor "
            "(canonical `Minor` or Pi `suggestion`)"
        ),
        (
            "That stream predates deep-review's merge-base Review Checklist "
            "suppression, so first drop every record whose `(file, line, "
            "category)` matches a finding that suppression removed and that "
            "is in the same class: advice (the split below), excuse (a "
            "`Documentation` finding above Minor whose summary begins with exactly "
            "`Excuse:`, the excuse class all three mirrors share) or neither"
        ),
        "Suppressing a candidate or any other finding then never drops a same-line excuse",
        "a misspelled or recased prefix included, stays actionable",
        "the projection rejects it with `passed gate has findings`",
        (
            "name the `file:line` of an excuse-class finding (`Documentation` "
            "above Minor with an `Excuse:` summary prefix, as the Pi documentation "
            "lens reports it) in the dispatched batch"
        ),
        "Backticks, quotes or brackets around the `file:line` and a leading `./` are ignored",
        (
            "Pi routes an unrepaired excuse through this `Excuse:` notice where "
            "the Claude and Codex gauntlets use Guardrail 1's quarantine path"
        ),
        "Keep their disk-first `Critical|Important|Minor` severities",
        "matched on file, line, category and summary",
        'Exclude only the findings `excuse_exclusions(proposal["summary"], batch)` returns',
        "a notice must open a line or sentence, carry a whole line number",
        (
            "notice in quoted prose (after an unclosed backtick or double quote "
            "on its line, on a `>` blockquote line or in a fenced block) excludes nothing"
        ),
        "same-line excuse-plus-candidate cannot merge into advice",
        "Retain each original gate envelope",
        "print advice once",
        "Do not claim that the raw review had no findings",
        "Advice-only input must not trigger a fixer or another round",
        "projection preserves skipped/degraded status and reason",
        "only projected gates to `PiLedger.append`",
        "never count advice",
        "exclude those findings from later fixer batches",
        "a quarantine is not convergence",
    ):
        assert phrase in text, phrase


def test_advice_projection_reads_canonical_disk_first_severity():
    candidate = documentation_finding(severity="Minor")
    excuse = documentation_finding("temporary hack", severity="Important")
    result = review_gauntlet.project_gate_findings(
        {"gate": "deep-review", "status": "findings", "findings": [candidate, excuse]}
    )
    assert result["advice"] == [candidate]
    assert result["gate"]["findings"] == [excuse]
    assert result["gate"]["findings"][0]["severity"] == "Important"


def test_passed_gate_with_findings_is_rejected_not_projected():
    raw = {
        "gate": "deep-review",
        "status": "passed",
        "findings": [documentation_finding()],
    }
    with pytest.raises(ValueError, match="passed gate has findings"):
        review_gauntlet.project_gate_findings(raw)
    with pytest.raises(ValueError, match="passed gate has findings"):
        pi_ledger.PiLedger._validate_round(
            {"status": "success", "gates": [raw], "findings_count": 0}
        )


def fixer_envelope(claimed, summary="done"):
    proposal = {
        "schema_version": 1,
        "status": "ok",
        "summary": summary,
        "claimed": claimed,
        "patches": [],
        "blast_radius": "local",
    }
    return {
        "status": "completed",
        "result": {
            "status": "ok",
            "findings": [],
            "artifact": {"format": "markdown", "content": json.dumps(proposal)},
        },
    }


def claim_for(finding, summary):
    return {
        "file": finding["file"],
        "line": finding["line"],
        "category": finding["category"],
        "summary": summary,
        "root_cause": "cause",
        "regression_test": "test",
    }


@pytest.mark.parametrize("batch_line", ["3", "03", 3])
def test_claim_line_matches_a_string_batch_line(batch_line):
    finding = documentation_finding("Excuse: temporary hack", line=batch_line)
    claim = claim_for(dict(finding, line=3), finding["summary"])
    accepted = review_gauntlet.validate_fixer_result(fixer_envelope([claim]), [finding])
    assert accepted["claimed"] == [claim]
    notice = "Excuse: x.py:3 cannot repair in scope."
    finding["severity"] = "Important"
    assert review_gauntlet.excuse_exclusions(notice, [finding]) == [finding]


def test_claim_must_match_batch_summary_not_only_location():
    excuse = documentation_finding("temporary hack", severity="Important")
    candidate_summary = documentation_finding()["summary"]
    with pytest.raises(ValueError, match="fixer_claim_not_in_batch"):
        review_gauntlet.validate_fixer_result(
            fixer_envelope([claim_for(excuse, candidate_summary)]), [excuse]
        )
    accepted = review_gauntlet.validate_fixer_result(
        fixer_envelope([claim_for(excuse, "  Temporary   HACK ")]), [excuse]
    )
    assert accepted["claimed"][0]["summary"] == "  Temporary   HACK "


def test_excuse_notice_excludes_only_cited_documentation_batch_findings():
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    critical = {
        "file": "x.py",
        "line": 9,
        "category": "Security",
        "severity": "Critical",
        "summary": "injection",
    }
    collected = documentation_finding(
        "Excuse: unlinked TODO", line="12", severity="Important"
    )
    stale = documentation_finding("stale name", line=14)
    minor = documentation_finding("tautology", line=15, severity="Minor")
    missing_doc = documentation_finding(
        "missing docs for the --timeout flag", line=16, severity="Important"
    )
    batch = [excuse, critical, collected, stale, minor, missing_doc]
    summary = (
        "Excuse: x.py:3 cannot repair in scope. Excuse: x.py:9 also skip. "
        "Excuse: x.py:12 skip. Excuse: x.py:14 stale. Excuse: x.py:15 restates. "
        "Excuse: x.py:16 out of scope. Excuse: other.py:3 not in batch."
    )
    assert review_gauntlet.excuse_exclusions(summary, batch) == [excuse, collected]
    assert review_gauntlet.excuse_exclusions("no notices", batch) == []


@pytest.mark.parametrize(
    "summary",
    [
        "Excuse: `x.py:3` cannot repair in scope.",
        "Excuse: [x.py:3] cannot repair in scope.",
        "Excuse: ./x.py:3 cannot repair in scope.",
        "Excuse: (`./x.py:3`), cannot repair in scope.",
    ],
)
def test_excuse_notice_ignores_quoting_and_a_leading_dot_slash(summary):
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    assert review_gauntlet.excuse_exclusions(summary, [excuse]) == [excuse]
    dotted = dict(excuse, file="./x.py")
    plain = "Excuse: x.py:3 cannot repair in scope."
    assert review_gauntlet.excuse_exclusions(plain, [dotted]) == [dotted]


@pytest.mark.parametrize(
    "summary",
    [
        "Excuse: x.py:3q not a whole line number",
        "Decision candidate: y.py:5 kept because Excuse: x.py:3 was quoted",
        "see Excuse: x.py:3 mid-sentence",
    ],
)
def test_excuse_notice_must_be_anchored_with_a_whole_line(summary):
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    assert review_gauntlet.excuse_exclusions(summary, [excuse]) == []


@pytest.mark.parametrize(
    "summary",
    [
        "Repaired one hack.\n- Excuse: x.py:3 cannot repair in scope.",
        "Repaired one hack.\n* Excuse: `x.py:3` cannot repair in scope.",
        "Repaired one hack.\n  Excuse: x.py:3 cannot repair in scope.",
        "Repaired one hack.\n1. Excuse: x.py:3 cannot repair in scope.",
    ],
)
def test_excuse_notice_accepts_indentation_and_a_list_marker(summary):
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    assert review_gauntlet.excuse_exclusions(summary, [excuse]) == [excuse]


def test_excuse_notice_accepts_a_backticked_path_with_spaces():
    excuse = documentation_finding(
        "Excuse: temporary hack", file="src/my module.py", line=17, severity="Important"
    )
    summary = "Excuse: `src/my module.py:17` cannot repair in scope."
    assert review_gauntlet.excuse_exclusions(summary, [excuse]) == [excuse]
    assert (
        review_gauntlet.excuse_exclusions(
            "Excuse: src/my module.py:17 unquoted", [excuse]
        )
        == []
    )


def test_excuse_notice_counts_at_a_line_start():
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    summary = "Repaired one hack.\nExcuse: x.py:3 cannot repair in scope."
    assert review_gauntlet.excuse_exclusions(summary, [excuse]) == [excuse]


@pytest.mark.parametrize(
    "summary",
    [
        'The reviewer wrote "Kept the hack. Excuse: x.py:3 later." in the log.',
        "Quoted `Kept the hack. Excuse: x.py:3 later.` here.",
        "> Kept the hack. Excuse: x.py:3 later.",
        "> Excuse: x.py:3 later.",
        "```\nExcuse: x.py:3 later.\n```",
        "The note \u201cKept it. Excuse: x.py:3 later.\u201d stays.",
    ],
)
def test_excuse_notice_inside_quoted_prose_is_ignored(summary):
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    assert review_gauntlet.excuse_exclusions(summary, [excuse]) == []


def test_excuse_notice_after_closed_quotes_still_counts():
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    summary = 'Fixed `foo` and "bar". Excuse: x.py:3 cannot repair in scope.'
    assert review_gauntlet.excuse_exclusions(summary, [excuse]) == [excuse]


def test_excuse_scan_is_bounded_on_long_whitespace_and_open_backticks():
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    hostile = [
        " " * 90_000,
        "\t" * 90_000 + "x",
        "- " + " \t" * 45_000,
        ". Excuse: `" * 9_000,
        ("a. " + " " * 60) * 1_000,
    ]
    start = time.perf_counter()
    for text in hostile:
        assert review_gauntlet.excuse_exclusions(text, [excuse]) == []
        notice = text[:3000] + "\nExcuse: x.py:3 cannot repair in scope."
        assert review_gauntlet.excuse_exclusions(notice, [excuse]) == [excuse]
    assert time.perf_counter() - start < 1.0


def test_excuse_notice_beyond_the_scan_limits_excludes_nothing():
    excuse = documentation_finding("Excuse: temporary hack", severity="Important")
    notice = "Excuse: x.py:3 cannot repair in scope."
    long_line = "x" * 5000 + ". " + notice
    assert review_gauntlet.excuse_exclusions(long_line, [excuse]) == []
    past_cap = ("filler\n" * 10_000) + notice
    assert review_gauntlet.excuse_exclusions(past_cap, [excuse]) == []


def test_excuse_notice_cut_by_the_scan_cap_cannot_cite_a_shorter_line():
    short = documentation_finding(
        "Excuse: temporary hack", severity="Important", line=12
    )
    cap = review_gauntlet._EXCUSE_SCAN_LIMIT
    cut = "\n" * (cap - len("Excuse: x.py:12")) + "Excuse: x.py:123"
    assert cut[:cap].endswith("Excuse: x.py:12")
    assert review_gauntlet.excuse_exclusions(cut, [short]) == []
    whole = cut[:cap] + "\nrest"
    assert review_gauntlet.excuse_exclusions(whole, [short]) == [short]


@pytest.mark.parametrize("severity", [["Minor"], {"level": "Minor"}])
def test_unhashable_severity_stays_actionable_instead_of_raising(severity):
    advice = documentation_finding(severity=severity)
    projected = review_gauntlet.project_gate_findings(
        {"gate": "deep-review", "status": "findings", "findings": [advice]}
    )
    assert projected["advice"] == []
    assert projected["gate"]["findings"] == [advice]
    excuse = documentation_finding("Excuse: temporary hack", severity=severity)
    notice = "Excuse: x.py:3 cannot repair in scope."
    assert review_gauntlet.excuse_exclusions(notice, [excuse]) == [excuse]


def test_refresh_removes_stale_entry_and_reprobes_available(tmp_path):
    cache = tmp_path / "capabilities.json"
    review_gauntlet.probe(
        "gate",
        fingerprint="fp",
        cache_path=cache,
        discover=lambda: (False, "gate_not_installed"),
    )
    result = review_gauntlet.probe(
        "gate",
        fingerprint="fp",
        cache_path=cache,
        discover=lambda: (True, None),
        refresh=True,
    )
    assert result.status == "available"
    assert (
        review_gauntlet.probe(
            "gate",
            fingerprint="fp",
            cache_path=cache,
            discover=lambda: (True, None),
        ).status
        == "available"
    )


def test_unknown_or_transient_absence_is_not_cached(tmp_path):
    cache = tmp_path / "capabilities.json"
    calls = []

    def inconclusive():
        calls.append(1)
        return False, None

    for _ in range(2):
        assert (
            review_gauntlet.probe(
                "gate", fingerprint="fp", cache_path=cache, discover=inconclusive
            ).status
            == "error"
        )
    assert len(calls) == 2

    cache.write_text(
        '{"schema_version":1,"entries":{"gate":{"status":"unavailable",'
        '"fingerprint":"fp","reason":"timeout"}}}'
    )
    assert (
        review_gauntlet.probe(
            "gate",
            fingerprint="fp",
            cache_path=cache,
            discover=lambda: (True, None),
        ).status
        == "available"
    )


def test_cache_write_failure_is_degraded(tmp_path, monkeypatch):
    monkeypatch.setattr(
        review_gauntlet.capability_cache,
        "record",
        lambda *args: (_ for _ in ()).throw(OSError("read-only")),
    )
    result = review_gauntlet.probe(
        "gate",
        fingerprint="fp",
        cache_path=tmp_path / "cache.json",
        discover=lambda: (False, "gate_not_installed"),
    )
    assert result.status == "error"
    assert result.reason == "capability_cache_write_failed"


def test_fixer_result_uses_generic_worker_envelope():
    envelope = {
        "status": "completed",
        "result": {
            "status": "ok",
            "findings": [],
            "artifact": {
                "format": "markdown",
                "content": '{"schema_version":1,"status":"ok","summary":"x",'
                '"claimed":[],"patches":[],"blast_radius":"local"}',
            },
        },
    }
    assert (
        review_gauntlet.validate_fixer_result(envelope, expected_findings=[])["patches"]
        == []
    )


def test_fixer_summary_notices_preserve_closed_proposal_and_batch():
    proposal = {
        "schema_version": 1,
        "status": "ok",
        "summary": "Excuse: x.py:3 cannot repair in scope. Decision candidate: y.py:5 choice",
        "claimed": [],
        "patches": [],
        "blast_radius": "local",
    }
    envelope = {
        "status": "completed",
        "result": {
            "status": "ok",
            "findings": [],
            "artifact": {"format": "markdown", "content": json.dumps(proposal)},
        },
    }
    assert review_gauntlet.validate_fixer_result(envelope, []) == proposal
    proposal["design_deltas"] = []
    envelope["result"]["artifact"]["content"] = json.dumps(proposal)
    with pytest.raises(ValueError, match="fixer_proposal_invalid"):
        review_gauntlet.validate_fixer_result(envelope, [])
    del proposal["design_deltas"]
    proposal["claimed"] = [
        {
            "file": "y.py",
            "line": 5,
            "category": "Documentation",
            "summary": "Decision candidate: choice",
            "root_cause": "choice",
            "regression_test": "none",
        }
    ]
    envelope["result"]["artifact"]["content"] = json.dumps(proposal)
    with pytest.raises(ValueError, match="fixer_claim_not_in_batch"):
        review_gauntlet.validate_fixer_result(
            envelope, [{"file": "x.py", "line": 3, "category": "Documentation"}]
        )


def test_refresh_failure_is_degraded(tmp_path, monkeypatch):
    monkeypatch.setattr(
        review_gauntlet.capability_cache,
        "clear_entry",
        lambda *args: (_ for _ in ()).throw(OSError("read-only")),
    )
    result = review_gauntlet.probe(
        "gate",
        fingerprint="fp",
        cache_path=tmp_path / "cache.json",
        discover=lambda: (True, None),
        refresh=True,
    )
    assert result.status == "error"
    assert result.reason == "capability_cache_refresh_failed"


def test_pi_ledger_rejects_unproven_success_and_is_resumable(tmp_path):
    ledger = pi_ledger.PiLedger(tmp_path / ".gauntlet" / "run.json", "branch:test")
    assert ledger.decision() == "no-rounds"
    ledger.init()
    try:
        ledger.append({"status": "success"})
    except ValueError as error:
        assert "gate evidence" in str(error)
    else:
        raise AssertionError("ledger accepted success without gate evidence")
    assert (
        ledger.append(
            {"status": "continue", "gates": [{"gate": "deep", "status": "passed"}]}
        )
        == "continue"
    )
    assert ledger.decision() == "continue"
    assert (
        ledger.append(
            {
                "status": "zero_runnable",
                "gates": [{"gate": "deep", "status": "skipped"}],
            }
        )
        == "zero_runnable"
    )
    assert ledger.read()["rounds"]


def test_pi_ledger_rejects_rounds_after_terminal(tmp_path):
    ledger = pi_ledger.PiLedger(tmp_path / "run.json", "target")
    ledger.path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "target": "target",
                "rounds": [
                    {"round": 1, "status": "zero_runnable"},
                    {"round": 2, "status": "continue"},
                ],
                "decision": "continue",
            }
        )
    )
    try:
        ledger.read()
    except ValueError:
        pass
    else:
        raise AssertionError("round after terminal decision was accepted")


def test_fixer_rejects_unclaimed_patches():
    envelope = {
        "status": "completed",
        "result": {
            "status": "ok",
            "findings": [],
            "artifact": {
                "format": "markdown",
                "content": '{"schema_version":1,"status":"ok","summary":"x",'
                '"claimed":[],"patches":[{"file":"x.py","old_text":"a",'
                '"new_text":"b"}],"blast_radius":"local"}',
            },
        },
    }
    try:
        review_gauntlet.validate_fixer_result(envelope, expected_findings=[])
    except ValueError as error:
        assert "without_claims" in str(error)
    else:
        raise AssertionError("unclaimed patch was accepted")


def test_pi_ledger_rejects_malformed_gate_evidence():
    cases = [
        {
            "status": "continue",
            "gates": [{"gate": "deep", "status": "passed", "findings": [None]}],
        },
        {
            "status": "continue",
            "gates": [{"gate": "deep", "status": "findings", "findings": []}],
        },
        {
            "status": "success",
            "gates": [
                {"gate": "deep", "status": "passed"},
                {"gate": "deep", "status": "passed"},
            ],
        },
    ]
    for case in cases:
        try:
            pi_ledger.PiLedger._validate_round(case)
        except ValueError:
            continue
        raise AssertionError("malformed gate evidence was accepted")


def test_pi_ledger_rejects_inconsistent_and_overlong_history(tmp_path):
    ledger = pi_ledger.PiLedger(tmp_path / "run.json", "target")
    ledger.path.write_text(
        '{"schema_version":1,"target":"target","rounds":[],"decision":"success"}'
    )
    try:
        ledger.read()
    except ValueError:
        pass
    else:
        raise AssertionError("inconsistent terminal decision was accepted")
    rounds = [{"round": index, "status": "continue"} for index in range(1, 12)]
    ledger.path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "target": "target",
                "rounds": rounds,
                "decision": "continue",
            }
        )
    )
    try:
        ledger.read()
    except ValueError:
        pass
    else:
        raise AssertionError("overlong ledger was accepted")


def test_pi_ledger_rejects_parent_traversal():
    try:
        pi_ledger.PiLedger(Path(".gauntlet/../outside/run.json"), "target").init()
    except ValueError as error:
        assert "traversal" in str(error)
    else:
        raise AssertionError("ledger accepted a parent-traversal path")
