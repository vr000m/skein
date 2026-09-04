"""Shared test scaffolding for the conduct skill's pytest suite.

Several test modules (``test_autonomous_mode.py``, ``test_ci_parity.py``)
need the same fixture-style helpers: a git-repo bootstrapper, a synthetic
plan generator, JSON-Lines report builders, a stub subagent spawner, and a
stub test runner. They previously held verbatim-duplicated copies of the
helpers; this module is the single source of truth.

The corresponding ``repo`` pytest fixture lives in ``conftest.py`` so it is
auto-injected without an explicit import. Pure-function helpers are
imported directly: ``from _scaffold import _git, _plan_with_phases, ...``.
"""

from __future__ import annotations

import json
import subprocess
import textwrap
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from conductor import SpawnRequest
from marker import write_marker
from runner import TestResult as _TestResult


def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, text=True, check=check
    )


def _plan_with_phases(n: int) -> str:
    parts = ["# Scratch", "## Implementation Checklist", ""]
    for i in range(1, n + 1):
        parts.append(f"### Phase {i}: Phase {i}")
        parts.append("")
        parts.append(f"**Impl files:** src/p{i}.py")
        parts.append(f"**Test files:** tests/test_p{i}.py")
        parts.append("**Test command:** `true`")
        parts.append("")
        parts.append(f"- [ ] task {i}")
        if i != n:
            parts.append("")
    return "\n".join(parts) + "\n"


def _scratch_plan(repo: Path, body: str, name: str = "20260513-scratch.md") -> Path:
    """Write ``body`` to ``docs/dev_plans/<name>`` in ``repo`` and stamp a
    review marker. The default name suits any single-plan test; callers that
    need to coexist with another plan in the same repo pass ``name=``.
    """
    plans_dir = repo / "docs" / "dev_plans"
    plans_dir.mkdir(parents=True, exist_ok=True)
    plan = plans_dir / name
    plan.write_text(textwrap.dedent(body))
    write_marker(plan)
    return plan


def _impl_report(label: str, files: list[str]) -> str:
    payload = {
        "role": "implementer",
        "phase_position": 0,
        "phase_label": label,
        "iteration": 0,
        "files_changed": files,
        "summary": "stub",
        "flags": {
            "blocked": False,
            "test_contract_mismatch": False,
            "explanation": None,
            "needs_test_coverage": [],
        },
    }
    return f"prose\n```json\n{json.dumps(payload)}\n```"


def _test_report(label: str = "1") -> str:
    payload = {
        "role": "test-writer",
        "phase_position": 0,
        "phase_label": label,
        "iteration": 0,
        "test_files_added": ["tests/test_a.py"],
        "test_commands": ["true"],
        "coverage_summary": "stub",
        "flags": {"blocked": False, "needs_impl_clarification": None},
    }
    return f"```json\n{json.dumps(payload)}\n```"


def _stage(repo: Path, path: str, content: str) -> None:
    full = repo / path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content)
    _git(["add", path], repo)


@dataclass
class StubSpawner:
    repo: Path
    scripts: dict[tuple[str, str, int], Callable[[SpawnRequest, Path], str]] = field(
        default_factory=dict
    )
    calls: list[SpawnRequest] = field(default_factory=list)

    def script(
        self,
        role: str,
        phase_label: str,
        iteration: int,
        fn: Callable[[SpawnRequest, Path], str],
    ) -> None:
        self.scripts[(role, phase_label, iteration)] = fn

    def __call__(self, req: SpawnRequest) -> str:
        self.calls.append(req)
        key = (req.role, req.phase_label, req.iteration)
        if key not in self.scripts:
            raise AssertionError(f"no scripted reply for {key}")
        return self.scripts[key](req, self.repo)


def _wire_normal_phase(spawner: StubSpawner, label: str) -> None:
    """Script implementer + test-writer for the named phase: stage one file
    under ``src/p<label>.py`` and emit a valid impl report.
    """

    def impl(req: SpawnRequest, r: Path) -> str:
        _stage(r, f"src/p{label}.py", f"v={label}\n")
        return _impl_report(label, [f"src/p{label}.py"])

    spawner.script("implementer", label, 0, impl)
    spawner.script("test-writer", label, 0, lambda req, r: _test_report(label))


@dataclass
class StubTestRunner:
    queue: list[_TestResult] = field(default_factory=list)
    calls: list[tuple[str, float]] = field(default_factory=list)

    def __call__(self, cmd: str, timeout: float) -> _TestResult:
        self.calls.append((cmd, timeout))
        if not self.queue:
            raise AssertionError(f"test runner exhausted (cmd={cmd!r})")
        return self.queue.pop(0)


def _passing() -> _TestResult:
    return _TestResult(
        returncode=0, output="ok\n", timed_out=False, duration_seconds=0.01
    )
