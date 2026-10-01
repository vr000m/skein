"""Phase 3 readiness tests for Pi review-gauntlet capability semantics."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / "plugins/skein-pi/lib"))

import pi_ledger
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
    assert request["role"] == "mechanical"
    assert '"no_nested_dispatch": true' in request["prompt"]
    assert '"kind": "review-gauntlet-fixer"' in request["prompt"]
    try:
        review_gauntlet.fixer_request([{"auto_fix": {}}])
    except ValueError as error:
        assert "auto_fix" in str(error)
    else:
        raise AssertionError("auto-fix proposal was accepted by Pi route")


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


def test_gauntlet_skill_is_not_registered_before_independent_review():
    root = Path(__file__).parents[2]
    manifest = (root / "package.json").read_text()
    assert "plugins/skein-pi/skills/review-gauntlet/SKILL.md" not in manifest
    assert (root / "plugins/skein-pi/skills/review-gauntlet/SKILL.md").is_file()
