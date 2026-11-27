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
    exercise_plan_path_command,
    selector_output,
    selector_status,
    with_paths,
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
    assert_decision_packet_contract(SKILL, "Architecture")
    text = SKILL.read_text()
    for phrase in (
        "tracked staged/unstaged paths",
        "Do not substitute unrelated current-diff paths for a plan target",
        "The selector's input has one source, the architecture worker's assigned units, the same list written for that lens to `expected.json`",
        "a rename counts as both its old and its new path",
        "Git reads a diff's file paths, never you and never the `diff --git` header text, which is a display format",
        "only then hand that file to this installed skill's `scripts/decision-paths.sh`",
        "Never pipe the diff into the script: the fence checks the diff's exit status first",
        "--src-prefix=a/ --dst-prefix=b/ --no-relative --ignore-submodules=none <packet diff arguments>",
        "the narrowed assignment is the one written to `expected.json`, and the selector takes that narrowed list, never the full diff",
        "it takes no range",
        "`--continue` remains unsupported",
        "untracked and ignored files are not part of it, and the selector still reads records from them",
        "Decision records: untracked or ignored records under docs/decisions are outside the reviewed scope",
    ):
        assert phrase in text, phrase
    for removed in ("--range-stdin", "SKEIN_RANGE", "--uncommitted", "--two-dot"):
        assert removed not in text, removed
    exercise_decision_selection(SKILL, tmp_path)


def test_deep_review_executes_documented_plan_command_fail_closed(tmp_path):
    exercise_plan_path_command(SKILL, tmp_path)


def test_deep_review_selector_input_is_the_architecture_assignment(tmp_path):
    """Fresh-ledger round 7. Old invariant: the selector re-derived the
    reviewed range itself (committed, staged and unstaged diffs). New
    invariant: the selector sees exactly the architecture worker's assigned
    paths, the list written to `expected.json`, so a narrowed packet narrows
    the selection too. Cells: target mode x shell; each checks (assigned
    paths) == (selector input paths) and the records selected, and the
    reference cell shows the full diff would select a record the narrowed
    worker never reviews."""
    repo, env, commands = decision_command_fixture(SKILL, tmp_path)
    command = next(command for command in commands if "--paths-stdin" in command)
    assert "--range-stdin" not in "".join(commands)
    (repo / "docs/dev_plans").mkdir(parents=True)
    (repo / "docs/dev_plans/plan.md").write_text("plan\n")
    (repo / "docs/decisions").mkdir()
    for name, applies in (
        ("20260101-cache.md", "src/cache/*"),
        ("20260102-auth.md", "src/auth/*"),
        ("20260103-moved.md", "old/moved.py"),
    ):
        (repo / "docs/decisions" / name).write_text(
            f"# {name}\n\n**Status**: active\n**Date**: 2026-11-24\n"
            f"**Applies to**: {applies}\n**Supersedes**: none\n"
            "**Superseded by**: none\n**Source plan**: docs/dev_plans/plan.md\n\n"
            "## Decision\nKeep it.\n## Why\nBecause.\n"
        )

    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args]).decode()

    ident = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    (repo / "old").mkdir()
    (repo / "old/moved.py").write_text("x\n")
    git("add", "--", "docs", "old")
    git(*ident, "commit", "-qm", "base")
    # Round 8: names git C-quotes or that hold ` b/`, plus a deletion and a
    # mode-only change, so a header splitter would get the paths wrong.
    hostile = ("src/archive/a b/src/cache/x.py", "src/r8/naïve.py", "src/r8/del.py")
    for path in (*hostile, "src/r8/mode.sh", "src/r8/sp ace.py"):
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text("base\n")
    git("add", "--", "src")
    git(*ident, "commit", "-qm", "hostile names")
    for path in ("src/cache/store.py", "src/auth/token.py"):
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text("change\n")
    for path in (
        "src/archive/a b/src/cache/x.py",
        "src/r8/naïve.py",
        "src/r8/sp ace.py",
    ):
        (repo / path).write_text("change\n")
    (repo / "src/r8/mode.sh").chmod(0o755)
    git("rm", "-q", "--", "src/r8/del.py")
    git("add", "--", "src")
    git(*ident, "commit", "-qm", "change")
    git("mv", "--", "old/moved.py", "new.py")

    def units_paths(diff_args):
        # The documented derivation: the skill's paths fence, which writes
        # the packet's diff to a file and hands it to decision-paths.sh.
        status, paths = run_paths_fence(repo, diff_args, "/bin/bash", repo)
        assert status == ("0", "0"), status
        return paths

    full = units_paths("-M HEAD~1")
    oracle = subprocess.check_output(
        ["git", "-C", str(repo), "diff", "--no-renames", "--name-only", "-z", "HEAD~1"]
    )
    assert full == sorted({p.decode() for p in oracle.split(b"\0") if p}), (
        "the derivation covers every path the diff changes, byte for byte"
    )
    assert {"old/moved.py", "new.py", "src/r8/naïve.py", "src/r8/mode.sh"} <= set(full)
    assert "src/cache/x.py b/src/archive/a b/src/cache/x.py" not in full

    def select(paths, shell):
        expected = tmp_path / "expected.json"
        expected.write_text(json.dumps({"architecture": paths}))
        assigned = json.loads(expected.read_text())["architecture"]
        script = with_paths(command, [f"p {path}" for path in assigned])
        written = sorted(
            line[2:] for line in script.splitlines() if line.startswith("p ")
        )
        assert written == sorted(paths), "selector input == assigned paths"
        result = subprocess.run(
            [shell, "-e", "-c", script],
            cwd=repo,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        assert selector_status(result) == 0, result.stderr
        named = Path(selector_output(result))
        text = named.read_text()
        named.unlink()
        return re.findall(r"^### Record: docs/decisions/(\S+)$", text, re.MULTILINE)

    shells = ["/bin/bash"] + ([shutil.which("zsh")] if shutil.which("zsh") else [])
    cells = (
        # current diff: committed range plus staged/unstaged, rename both sides;
        # `src/archive/a b/src/cache/x.py` is not a cache path
        (full, ["20260101-cache.md", "20260102-auth.md", "20260103-moved.md"]),
        # the ` b/` directory alone selects no record
        (["src/archive/a b/src/cache/x.py"], []),
        # narrowed packet: only the units the worker is assigned
        (["src/cache/store.py"], ["20260101-cache.md"]),
        # plan target without a diff: the plan's named paths
        (["src/auth/token.py"], ["20260102-auth.md"]),
    )
    for shell in shells:
        for paths, want in cells:
            assert select(paths, shell) == want, (shell, paths)
    # Reference: the full diff selects records the narrowed worker never saw.
    assert select(full, "/bin/bash") != select(["src/cache/store.py"], "/bin/bash")


def paths_fence():
    """The Pi skill's documented decision-paths fence."""
    return next(
        command
        for command in re.findall(r"```bash\n(.*?)\n```", SKILL.read_text(), re.DOTALL)
        if "$DECISION_PATHS" in command
    )


def run_paths_fence(repo, diff_args, shell, cwd, path_prefix=""):
    """Runs the paths fence with `<packet diff arguments>` filled in; returns
    ((diff-exit, paths-exit), the paths or None) and removes its folder."""
    script = paths_fence().replace("<packet diff arguments>", diff_args)
    result = subprocess.run(
        [shell, "-e", "-c", script],
        cwd=cwd,
        env={
            **os.environ,
            "PATH": path_prefix + os.environ["PATH"],
            "REAL_GIT": shutil.which("git"),
            "DECISION_PATHS": str(SKILL.parent / "scripts/decision-paths.sh"),
        },
        capture_output=True,
        text=True,
        check=False,
    )
    fields = dict(
        line.split("=", 1) for line in result.stdout.splitlines() if "=" in line
    )
    status = (fields.get("diff-exit"), fields.get("paths-exit"))
    paths_file = Path(fields["paths-file"])
    folder = paths_file.parent
    assert not (folder / "lens-diff.patch").exists(), "the patch is removed"
    paths = None
    if status == ("0", "0"):
        paths = json.loads(paths_file.read_text())
    else:
        assert not paths_file.exists(), "a failed step publishes no paths"
    shutil.rmtree(folder)
    return status, paths


def test_deep_review_paths_fence_reads_a_complete_prefixed_patch_from_the_top(
    tmp_path,
):
    """Fresh-ledger round 9. Old invariant: the paths came from whatever patch
    and cwd decision-paths.sh was given, piped from the packet's diff. New
    invariant: the fence pins the diff's prefixes, checks the diff's exit
    status before the script reads it, and the script reads the patch from
    the repo's top level. Cells: shell x {top, subdirectory, diff.noprefix,
    custom prefixes, diff.relative from a subdirectory, a diff that prints one
    complete file patch and then exits 9}."""
    repo = tmp_path / "repo"
    repo.mkdir()

    def git(*args):
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "-c",
                "user.name=F",
                "-c",
                "user.email=f@f",
                *args,
            ],
            check=True,
            capture_output=True,
        )

    git("init", "-q")
    for path in ("outside/a.txt", "outside/mv.txt", "sub/deep/in.py"):
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text("base\n")
    git("add", "--", "outside", "sub")
    git("commit", "-qm", "base")
    (repo / "outside/a.txt").write_text("change\n")
    (repo / "sub/deep/in.py").write_text("change\n")
    git("mv", "--", "outside/mv.txt", "sub/mv.txt")
    git("commit", "-qam", "change")
    want = ["outside/a.txt", "outside/mv.txt", "sub/deep/in.py", "sub/mv.txt"]
    shim = tmp_path / "shim"
    shim.mkdir()
    (shim / "git").write_text(
        '#!/bin/sh\nif [ "$1" = diff ]; then\n'
        '\t"$REAL_GIT" "$@" -- sub/deep/in.py\n\texit 9\nfi\nexec "$REAL_GIT" "$@"\n'
    )
    (shim / "git").chmod(0o755)
    configs = {
        "top": ((), repo),
        "subdirectory": ((), repo / "sub"),
        "noprefix": ((("diff.noprefix", "true"),), repo),
        "custom": ((("diff.srcPrefix", "x/"), ("diff.dstPrefix", "y/")), repo),
        "relative": ((("diff.relative", "true"),), repo / "sub"),
    }
    shells = ["/bin/bash"] + ([shutil.which("zsh")] if shutil.which("zsh") else [])
    for shell in shells:
        for name, (settings, cwd) in configs.items():
            for key, value in settings:
                git("config", key, value)
            try:
                status, paths = run_paths_fence(repo, "-M HEAD~1 HEAD", shell, cwd)
            finally:
                for key, _value in settings:
                    git("config", "--unset", key)
            assert (status, paths) == (("0", "0"), want), (shell, name)
        status, paths = run_paths_fence(
            repo, "-M HEAD~1 HEAD", shell, repo, f"{shim}{os.pathsep}"
        )
        assert status == ("9", "skipped") and paths is None, (shell, status)


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
