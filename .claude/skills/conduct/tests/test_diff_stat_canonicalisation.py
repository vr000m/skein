"""Unit tests for ``progress.compute_staged_diff_stat``.

The two tests assert that:

- Stat mode (``_USE_STAT_W=True``) collapses pure-whitespace edits so a
  whitespace-only iteration produces a signature that matches the next
  iteration's signature, exposing a stalled implementer that's only
  reformatting.
- Fallback mode (``_USE_STAT_W=False``) yields the sorted file list
  independent of git's natural reporting order.

Each test builds a synthetic git repo in ``tmp_path`` so the call exercises a
real ``git diff --cached`` invocation against real index state.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

import progress


def _git(args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, text=True, check=True
    )


def _init_repo(repo: Path) -> None:
    _git(["init", "-q"], repo)
    _git(["config", "user.email", "h@t"], repo)
    _git(["config", "user.name", "Harness"], repo)
    _git(["config", "commit.gpgsign", "false"], repo)


def test_compute_staged_diff_stat_w_mode_whitespace_collapses(monkeypatch, tmp_path):
    """``_USE_STAT_W=True``: whitespace-only edits are collapsed against
    content-bearing edits in the same file.

    Stage two variants of the same file: one with a trailing-space-only edit,
    one with a content-bearing edit. Under ``--stat -w`` the whitespace-only
    iteration reports zero stat changes while the content-bearing iteration
    reports a non-zero stat. Therefore the canonicalised outputs DIFFER
    between the two iterations — but two whitespace-only iterations against
    the same baseline produce IDENTICAL output (the property we rely on to
    flag whitespace-only stalls).
    """
    if not progress._USE_STAT_W:
        pytest.skip(
            "this environment's git does not support `--stat -w`; "
            "fallback-mode test exercises the other branch"
        )
    monkeypatch.setattr(progress, "_USE_STAT_W", True)

    _init_repo(tmp_path)
    src = tmp_path / "src.py"
    src.write_text("def f():\n    return 1\n")
    _git(["add", "src.py"], tmp_path)
    _git(["commit", "-q", "-m", "seed"], tmp_path)

    # Iteration A: whitespace-only edit (trailing space on a line).
    src.write_text("def f():    \n    return 1\n")
    _git(["add", "src.py"], tmp_path)
    stat_ws_1 = progress.compute_staged_diff_stat(tmp_path)

    # Reset, then re-stage the same whitespace-only edit (different actual
    # spacing but still whitespace-only).
    _git(["reset", "-q", "HEAD", "src.py"], tmp_path)
    src.write_text("def f():\n    return 1\n")  # restore canonical form
    src.write_text("def f():\t\n    return 1\n")  # whitespace-only delta (tab)
    _git(["add", "src.py"], tmp_path)
    stat_ws_2 = progress.compute_staged_diff_stat(tmp_path)

    # Both whitespace-only stagings are equivalent under --stat -w: zero
    # insertions, zero deletions. The canonical string therefore matches.
    assert stat_ws_1 == stat_ws_2, (
        f"whitespace-only edits did not collapse: {stat_ws_1!r} != {stat_ws_2!r}"
    )

    # Sanity: a content-bearing edit yields a DIFFERENT canonical output, so
    # the collapse above is not an artefact of all output being empty.
    _git(["reset", "-q", "HEAD", "src.py"], tmp_path)
    src.write_text("def f():\n    return 999\n")
    _git(["add", "src.py"], tmp_path)
    stat_content = progress.compute_staged_diff_stat(tmp_path)
    assert stat_content != stat_ws_1


def test_compute_staged_diff_stat_fallback_mode_deterministic_sort(
    monkeypatch, tmp_path
):
    """``_USE_STAT_W=False``: output is the sorted file list regardless of
    git's reporting order.

    Stage three files in a deliberate non-alphabetical order; the canonical
    output must still be alphabetically sorted.
    """
    monkeypatch.setattr(progress, "_USE_STAT_W", False)

    _init_repo(tmp_path)
    # Seed the repo so the index has somewhere to compare.
    (tmp_path / "seed.txt").write_text("seed\n")
    _git(["add", "seed.txt"], tmp_path)
    _git(["commit", "-q", "-m", "seed"], tmp_path)

    # Stage files in a deliberately scrambled order.
    for name in ("z.py", "a.py", "m.py"):
        (tmp_path / name).write_text(f"# {name}\n")
        _git(["add", name], tmp_path)

    out = progress.compute_staged_diff_stat(tmp_path)
    lines = [ln for ln in out.splitlines() if ln]
    assert lines == sorted(lines)
    assert lines == ["a.py", "m.py", "z.py"]
    # Trailing newline so two empty-vs-nonempty results are textually
    # distinguishable.
    assert out.endswith("\n")
