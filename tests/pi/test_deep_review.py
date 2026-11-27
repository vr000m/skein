"""Readiness gates for the staged Pi deep-review port."""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

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
from test_review import (
    assert_decision_packet_contract,
    decision_command_fixture,
    exercise_decision_selection,
    selector_output,
    selector_status,
)


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
        "a misspelled or recased prefix included, is reconciled like every other finding",
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
        "sets exact-prefix candidates aside before reconciliation and appends them unmerged",
        "after exact-prefix Minor `Decision candidate:` advice rows are set aside",
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
        "decisions-active.sh",
        "lens-budget.sh",
        "persist-deep-review-state.sh",
        "persist-lens-result.sh",
        "reconcile-findings.sh",
    }
    assert names <= {path.name for path in bundled.iterdir() if path.is_file()}
    for name in names:
        assert (bundled / name).read_bytes() == (ROOT / "scripts" / name).read_bytes()
    for name in (
        "auto-fix-common.sh",
        "lens-common.sh",
        "persist-common.sh",
        "decisions-common.sh",
    ):
        assert (bundled / "lib" / name).read_bytes() == (
            ROOT / "scripts/lib" / name
        ).read_bytes()


def test_deep_review_decision_packet_contract_and_selector_fixtures(tmp_path):
    assert_decision_packet_contract(SKILL, "Architecture", all_active=True)
    text = SKILL.read_text()
    for phrase in (
        "run it once with `--all-active`: it derives no paths, takes no range and reads no stdin",
        "a record binds only if at least one of its `Applies to` globs matches a file changed in the diff the worker reviews",
        "Tell the architecture worker that the block holds every active record, not only those that apply",
        "Decision records omitted: N of M active records shown; coverage is partial.",
        "`--continue` remains unsupported",
        "untracked and ignored files are not part of it, and the selector still reads records from them",
        "Decision records: untracked or ignored records under docs/decisions are outside the reviewed scope",
    ):
        assert phrase in text, phrase
    for removed in (
        "--range-stdin",
        "SKEIN_RANGE",
        "--uncommitted",
        "--two-dot",
        "decision-paths",
        "DECISION_PATHS",
        "--paths-stdin",
        "SKEIN_PATHS",
    ):
        assert removed not in text, removed
    exercise_decision_selection(SKILL, tmp_path)


def test_deep_review_all_active_command_yields_every_active_record(tmp_path):
    """The decision-paths removal (option b). Old invariant: the Pi skill fed
    the selector the paths decision-paths.sh read from the packet's diff. New
    invariant: its one selector command runs --all-active with no path, so
    under bash and zsh it yields every active record (an independent read of
    the Status headers), never a superseded one, whatever the reviewed diff;
    a path-matching mutant of the same command drops a record."""
    repo, env, commands = decision_command_fixture(SKILL, tmp_path)
    selector_commands = [c for c in commands if '"$SELECTOR"' in c]
    assert len(selector_commands) == 1, selector_commands
    command = selector_commands[0]
    assert '"$SELECTOR" --temp-output --all-active || selector_exit=$?' in command
    records = repo / "docs/decisions"
    records.mkdir(parents=True)
    (repo / "docs/dev_plans").mkdir()
    (repo / "docs/dev_plans/source.md").write_text("# Source\n")

    def record(name, applies, status="active", supersedes="none", successor="none"):
        (records / name).write_text(
            f"# Choice\n\n**Status**: {status}\n**Date**: 2026-11-22\n"
            f"**Applies to**: {applies}\n"
            f"**Supersedes**: {supersedes}\n**Superseded by**: {successor}\n"
            "**Source plan**: docs/dev_plans/source.md\n\n"
            "## Decision\nKeep it.\n## Why\nBecause.\n"
        )

    record("20261101-old.md", "src/*", "superseded", successor="20261102-new.md")
    record("20261102-new.md", "src/*", supersedes="20261101-old.md")
    record("20261103-far.md", "nowhere/*")
    want = sorted(
        path.name
        for path in records.iterdir()
        if "**Status**: active\n" in path.read_text()
    )
    assert want == ["20261102-new.md", "20261103-far.md"]
    tmpdir = tmp_path / "tmpdir"
    tmpdir.mkdir()
    shells = ["/bin/bash"] + ([shutil.which("zsh")] if shutil.which("zsh") else [])

    def selected(script, shell):
        result = subprocess.run(
            [shell, "-e", "-c", script],
            cwd=repo,
            env={**env, "TMPDIR": str(tmpdir)},
            capture_output=True,
            text=True,
            check=False,
        )
        assert selector_status(result) == 0, (shell, result.stderr)
        named = Path(selector_output(result))
        assert named.parent == tmpdir and named.stat().st_mode & 0o777 == 0o600
        text = named.read_text()
        named.unlink()
        return sorted(
            re.findall(r"^### Record: docs/decisions/(\S+)$", text, re.MULTILINE)
        )

    for shell in shells:
        assert selected(command, shell) == want, shell
    mutant = command.replace("--all-active", "-- src/x.py")
    assert mutant != command
    assert selected(mutant, "/bin/bash") == ["20261102-new.md"], "mutant drops a record"
    status = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain", "--ignored", "--", "."],
        capture_output=True,
        text=True,
        check=True,
    )
    assert ".deep-review" not in status.stdout, "the command writes no state"


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
