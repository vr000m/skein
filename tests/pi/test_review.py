"""Readiness contracts for the Pi review-plan workflow."""

import json
import os
import subprocess

from test_package import ALLOWLIST, COMMANDS, ROOT

SKILL = ROOT / "plugins/skein-pi/skills/review-plan/SKILL.md"
SCRIPT_NAMES = {
    "apply-auto-fix-plan.sh",
    "audit-auto-fix-eligibility.sh",
    "collect-lens-results.sh",
    "lens-budget.sh",
    "persist-lens-result.sh",
    "persist-review-state.sh",
    "plan-scope-detect.sh",
    "reconcile-findings.sh",
    "write-review-marker.py",
}


def test_review_plan_is_explicitly_registered_and_not_a_wildcard():
    manifest = json.loads((ROOT / "package.json").read_text())
    assert manifest["pi"]["skills"] == ALLOWLIST
    assert "./plugins/skein-pi/skills/review-plan/SKILL.md" in ALLOWLIST
    assert all("*" not in path and not path.endswith("/") for path in ALLOWLIST)
    assert "skill:skein-review-plan" in COMMANDS


def test_review_plan_has_portable_disk_first_and_degraded_contract():
    text = SKILL.read_text()
    assert text.startswith("---\nname: skein-review-plan\n")
    for forbidden in ("CLAUDE_PLUGIN_ROOT", "$SKILL_DIR", "spawn_agent", "Agent"):
        assert forbidden not in text
    for phrase in (
        "top-level review orchestrator",
        "explicit approval before every worker launch",
        "persist-lens-result.sh",
        "collect-lens-results.sh",
        "expected.json",
        "skipped",
        "Do not cache timeouts",
        "persist-review-state.sh --harness pi",
        "latest-pi.json",
        "never treat a skipped gate as a clean approval",
        "main session owns this adapter",
        "--json-file",
        "skein-dev-plan update",
        "Never calculate or refresh the marker by hand",
    ):
        assert phrase in text


def test_review_plan_capability_cache_is_packaged_separately_from_results():
    cache = ROOT / "plugins/skein-pi/lib/capability_cache.py"
    assert cache.is_file()
    text = cache.read_text()
    assert 'STABLE_STATUS = "unavailable"' in text
    assert "fingerprint" in text and "clear" in text


def test_review_plan_bundles_only_required_canonical_scripts():
    bundled = SKILL.parent / "scripts"
    assert {path.name for path in bundled.iterdir() if path.is_file()} >= SCRIPT_NAMES
    for name in SCRIPT_NAMES:
        assert (bundled / name).read_bytes() == (ROOT / "scripts" / name).read_bytes()
    assert (bundled / "lib" / "persist-common.sh").read_bytes() == (
        ROOT / "scripts/lib/persist-common.sh"
    ).read_bytes()
    assert not (bundled / "render-reconciled-report.sh").exists()


def test_pi_review_state_persistence_writes_distinct_latest_file(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
    envelope = repo / "envelope.json"
    envelope.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "summary": {},
                "findings": [],
                "related": [],
            }
        )
    )
    script = SKILL.parent / "scripts" / "persist-review-state.sh"
    result = subprocess.run(
        [
            str(script),
            "--harness",
            "pi",
            "--plan-path",
            "docs/dev_plans/fixture.md",
            "--plan-hash",
            "0" * 40,
            "--run-id",
            "fixture",
            str(envelope),
        ],
        cwd=repo,
        env={"PATH": os.environ["PATH"]},
        text=True,
        capture_output=True,
        check=True,
    )
    state = repo / ".review-plan/latest-pi.json"
    assert result.stdout.strip() == str(state)
    assert json.loads(state.read_text())["plan_path"] == "docs/dev_plans/fixture.md"


def test_review_plan_exclusions_remain_absent_from_manifest():
    manifest = json.loads((ROOT / "package.json").read_text())
    for name in (
        "plan-view",
        "rfc-finder",
        "spec-compliance",
        "deep-review",
        "review-gauntlet",
    ):
        assert (
            f"./plugins/skein-pi/skills/{name}/SKILL.md" not in manifest["pi"]["skills"]
        )
    assert not (ROOT / "plugins/skein-pi/skills/deep-review").exists()
    assert not (ROOT / "plugins/skein-pi/skills/review-gauntlet").exists()
