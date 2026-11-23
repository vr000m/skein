"""Readiness gates for the staged Pi deep-review port."""

import json
import os
import re
import subprocess
import sys

from test_package import (
    ALLOWLIST,
    COMMANDS,
    ROOT,
    assert_discovery,
    package_fixture,
    run,
)
from test_package import sandbox as sandbox  # noqa: PLC0414 — pytest fixture re-export

SKILL = ROOT / "plugins/skein-pi/skills/deep-review/SKILL.md"
sys.path.insert(0, str(ROOT / "plugins/skein-pi/lib"))

import review_gauntlet


def test_deep_review_is_registered_after_readiness_review():
    manifest = json.loads((ROOT / "package.json").read_text())
    assert "./plugins/skein-pi/skills/deep-review/SKILL.md" in ALLOWLIST
    assert "./plugins/skein-pi/skills/deep-review/SKILL.md" in manifest["pi"]["skills"]
    assert "skill:skein-deep-review" in COMMANDS


def test_deep_review_has_pi_native_bounded_disk_first_contract():
    text = SKILL.read_text()
    assert text.startswith("---\nname: skein-deep-review\n")
    for forbidden in ("CLAUDE_PLUGIN_ROOT", "$SKILL_DIR", "spawn_agent", "Agent"):
        assert forbidden not in text
    for phrase in (
        "does not accept PR numbers/URLs or `--continue`",
        "Read this installed `rubric.md` as trusted instructions",
        "reviewed_units",
        "persist-lens-result.sh --json-file",
        "collect-lens-results.sh",
        "--findings-jsonl",
        "persist-deep-review-state.sh --harness pi --from-collector",
        "automated fixes are unsupported",
        "Never rewrite `expected.json`",
        "Never call unavailable or skipped coverage a clean review",
    ):
        assert phrase in text
    rubric = SKILL.with_name("rubric.md").read_text()
    assert "auto_fix` proposals and application are unsupported" in rubric


def test_documentation_packet_and_lens_are_added_diff_only():
    text = " ".join(SKILL.read_text().split())
    rubric = " ".join(SKILL.with_name("rubric.md").read_text().split())
    for phrase in (
        "added-line coordinates (`file` and new-side line number) and adjacent code",
        "removed or renamed symbols shown by that same diff",
        "no whole-file evidence step or symbol inventory lookup",
        "Validate each added-comment finding's location against an actual added line",
        "plan target without an actual diff, do not invent added-comment findings",
        "Use the user's currently selected model",
        "Require explicit approval for each worker launch",
        "Keep raw Documentation findings",
        "preserve that exact prefix unchanged during severity mapping",
        "first set aside every row that is advice (category `Documentation`, severity `Minor`",
        "or a near miss of that prefix",
        "append the set-aside rows to its `findings` unmerged, one finding each",
        "add their count to `summary.raw` and `summary.unique`",
        "a review whose only findings are set-aside rows is not clean",
        "findings, set-aside rows included, grouped",
    ):
        assert phrase in text, phrase
    for phrase in (
        "Comments the diff ADDS (never pre-existing comments)",
        "excuse (Important; worker `important`)",
        'hack, workaround, temporary, "for now", or a TODO without an issue link',
        "tautology (Minor; worker `suggestion`)",
        "words restate the identifiers of the adjacent line",
        "stale (Minor; worker `suggestion`)",
        "symbol that the same diff removes or renames",
        "decision candidate (Minor, informational; worker `suggestion`)",
        "`because`, `instead of`, `rather than`, `chose`",
        "exactly `Decision candidate:`",
        "category `Documentation` and location at the added line",
        "docstrings, linter and type pragmas, license headers",
        "a full issue URL or `#N`",
        "Do not look up symbols outside the supplied diff",
        (
            "One class per comment: when a comment matches more than one class, "
            "report it once, under the first that matches in the order excuse, "
            "stale, tautology, decision candidate."
        ),
        "Never relabel an excuse as advice",
        "Begin its `summary` with exactly `Excuse:`",
        "sets candidates and near misses aside before reconciliation and appends them unmerged",
        "(exact-prefix Minor advice and near misses) are set aside and appended back unmerged",
    ):
        assert phrase in rubric, phrase


def _skill_severity_map():
    match = re.search(
        r"map `([a-z|]+)` to `([A-Za-z|]+)`", " ".join(SKILL.read_text().split())
    )
    assert match, "SKILL.md no longer states the worker-to-disk severity map"
    return dict(zip(match[1].split("|"), match[2].split("|"), strict=True))


def test_documentation_synthetic_packet_preserves_severity_and_raw_advice(tmp_path):
    packet = {
        "diff": (
            "--- a/x.py\n+++ b/x.py\n@@ -1,2 +1,4 @@\n"
            " # pre-existing comment\n-old_name()\n"
            "+# temporary hack; chose new_name instead of old_name\n+new_name()\n"
        ),
        "added_lines": {"x.py": [2, 3]},
        "adjacent_code": "new_name()",
        "removed_or_renamed_symbols": ["old_name"],
    }
    worker_findings = [
        {
            "category": "Documentation",
            "severity": "important",
            "location": "x.py:2",
            "summary": "Excuse: temporary hack",
            "evidence": "# temporary hack next to new_name()",
            "recommendation": "Repair the hack",
        },
        {
            "category": "Documentation",
            "severity": "suggestion",
            "location": "x.py:2",
            "summary": "Decision candidate: chose new_name instead of old_name",
            "evidence": "added choice comment next to new_name()",
            "recommendation": "Keep the comment",
        },
    ]
    assert "-old_name()" in packet["diff"]
    assert "old_name" in packet["removed_or_renamed_symbols"]
    assert 1 not in packet["added_lines"]["x.py"]
    severity_map = _skill_severity_map()
    assert severity_map == {
        "critical": "Critical",
        "important": "Important",
        "suggestion": "Minor",
    }
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
    scripts = SKILL.parent / "scripts"
    persist = [
        str(scripts / "persist-lens-result.sh"),
        "--root",
        str(repo),
        "--skill",
        "deep-review",
        "--run-id",
        "documentation-fixture",
        "--lens",
        "documentation",
        "--attempt",
        "1",
        "--json-file",
    ]
    records = [
        {"type": "start", "units": ["x.py"]},
        {"type": "progress", "unit": "x.py"},
    ]
    for finding in worker_findings:
        file, line = finding["location"].rsplit(":", 1)
        assert int(line) in packet["added_lines"][file]
        records.append(
            {
                "type": "finding",
                **{
                    key: finding[key]
                    for key in ("category", "location", "summary", "evidence")
                },
                "severity": severity_map[finding["severity"]],
                "suggestion": finding["recommendation"],
            }
        )
    records.append({"type": "done", "status": "completed"})
    for index, record in enumerate(records):
        path = tmp_path / f"record-{index}.json"
        path.write_text(json.dumps(record))
        subprocess.run([*persist, str(path)], check=True, capture_output=True)
    collected = subprocess.run(
        [
            str(scripts / "collect-lens-results.sh"),
            "--root",
            str(repo),
            "--skill",
            "deep-review",
            "--run-id",
            "documentation-fixture",
            "--expected",
            "documentation:x.py",
            "--findings-jsonl",
        ],
        cwd=repo,
        text=True,
        capture_output=True,
        check=True,
    )
    raw = [json.loads(line) for line in collected.stdout.splitlines()]
    assert [(item["severity"], item["summary"]) for item in raw] == [
        ("Important", "Excuse: temporary hack"),
        ("Minor", "Decision candidate: chose new_name instead of old_name"),
    ]
    projection = review_gauntlet.project_gate_findings(
        {"gate": "deep-review", "status": "findings", "findings": raw}
    )
    assert [item["summary"] for item in projection["advice"]] == [
        "Decision candidate: chose new_name instead of old_name"
    ]
    actionable = projection["gate"]["findings"]
    reconciled = subprocess.run(
        [str(scripts / "reconcile-findings.sh"), "--skill", "deep-review"],
        input="".join(json.dumps(item) + "\n" for item in actionable),
        text=True,
        capture_output=True,
        check=True,
    )
    merged = json.loads(reconciled.stdout)["findings"]
    assert [(item["severity"], item["summary"]) for item in merged] == [
        ("Important", "Excuse: temporary hack")
    ]


def test_deep_review_bundles_canonical_required_scripts():
    bundled = SKILL.parent / "scripts"
    names = {
        "audit-auto-fix-eligibility.sh",
        "collect-lens-results.sh",
        "lens-budget.sh",
        "persist-deep-review-state.sh",
        "persist-lens-result.sh",
        "reconcile-findings.sh",
    }
    assert names <= {path.name for path in bundled.iterdir() if path.is_file()}
    for name in names:
        assert (bundled / name).read_bytes() == (ROOT / "scripts" / name).read_bytes()
    for name in ("auto-fix-common.sh", "lens-common.sh", "persist-common.sh"):
        assert (bundled / "lib" / name).read_bytes() == (
            ROOT / "scripts/lib" / name
        ).read_bytes()


def test_staged_deep_review_installs_and_expands_in_disposable_pi(tmp_path, sandbox):
    pi, env, cwd, _agent = sandbox
    package = package_fixture(tmp_path / "registered deep-review")
    run([pi, "install", str(package)], env, cwd)
    assert_discovery(sandbox, package)
    run([pi, "remove", str(package)], env, cwd)


def test_pi_deep_review_persistence_uses_distinct_state_file(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
    script = SKILL.parent / "scripts" / "persist-deep-review-state.sh"
    result = subprocess.run(
        [
            str(script),
            "--harness",
            "pi",
            "--run-id",
            "fixture",
            "--base-commit",
            "base-sha",
            "--head-commit",
            "head-sha",
            "--diff-hash",
            "sha256:diff",
            "--review-focus-hash",
            "",
            "--from-collector",
        ],
        input=json.dumps({"logic": {"status": "completed", "findings": []}}),
        cwd=repo,
        env={"PATH": os.environ["PATH"]},
        text=True,
        capture_output=True,
        check=True,
    )
    state = repo / ".deep-review/latest-pi.json"
    assert result.stdout.strip() == str(state)
    saved = json.loads(state.read_text())
    assert saved["schema_version"] == 2
    assert saved["lenses"]["logic"]["status"] == "completed"
