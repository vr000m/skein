from __future__ import annotations

import importlib
import subprocess
from pathlib import Path

import pytest


def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, text=True, check=check
    )


@pytest.fixture
def git_repo(tmp_path: Path) -> Path:
    _git(["init", "-q"], tmp_path)
    _git(["config", "user.email", "progress@test"], tmp_path)
    _git(["config", "user.name", "Progress"], tmp_path)
    _git(["config", "commit.gpgsign", "false"], tmp_path)
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "a.py").write_text("value = 1\n")
    (tmp_path / "src" / "b.py").write_text("value = 1\n")
    _git(["add", "src/a.py", "src/b.py"], tmp_path)
    _git(["commit", "-q", "-m", "seed"], tmp_path)
    return tmp_path


def _progress_module():
    try:
        return importlib.import_module("conduct.progress")
    except ModuleNotFoundError as exc:
        pytest.fail(f"conduct.progress module is missing: {exc}")


def test_compute_staged_diff_stat_w_mode_whitespace_collapses(
    git_repo: Path, monkeypatch: pytest.MonkeyPatch
):
    progress = _progress_module()
    monkeypatch.setattr(progress, "_USE_STAT_W", True)

    (git_repo / "src" / "a.py").write_text("value    =    1\n")
    _git(["add", "src/a.py"], git_repo)

    assert progress.compute_staged_diff_stat(git_repo) == ""

    (git_repo / "src" / "a.py").write_text("value = 2\n")
    _git(["add", "src/a.py"], git_repo)

    stat = progress.compute_staged_diff_stat(git_repo)
    assert "src/a.py" in stat


def test_compute_staged_diff_stat_fallback_mode_deterministic_sort(
    git_repo: Path, monkeypatch: pytest.MonkeyPatch
):
    progress = _progress_module()
    monkeypatch.setattr(progress, "_USE_STAT_W", False)

    (git_repo / "src" / "b.py").write_text("value = 2\n")
    (git_repo / "src" / "a.py").write_text("value = 2\n")
    _git(["add", "src/b.py", "src/a.py"], git_repo)

    assert progress.compute_staged_diff_stat(git_repo) == "src/a.py\nsrc/b.py\n"
