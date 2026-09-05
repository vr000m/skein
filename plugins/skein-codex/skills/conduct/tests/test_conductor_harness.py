"""Stub-spawner harness tests for the conductor algorithm.

Covers Phase 6 scenarios that depend on subagent branching but don't require
spawning real delegated subagents:

- Happy path (single phase, both subagents succeed first try)
- Multi-phase happy path via --resume
- Assertion failure → implementer respawn → pass on iteration 1
- Test contract mismatch → test-writer respawn on iteration 1
- Fix-loop cap (3 iterations → blocked)
- Pre-existing lint failure (preflight hard stop)
- Missing test command (skip-with-warning, phase still completes)
- Pre-commit hook failure routed to fix loop (counts as iteration, not error)
- Pause / abort flag behaviour
- Rogue commit detection (subagent committed during its own work)
- Schema error → no respawn, hard stop with status='schema_error'
- Context isolation (sentinel from parent context never leaks into prompts)

The conductor algorithm and the spawn seam are exercised inside a real ``git
init`` repo under ``tmp_path`` so commit / diff / rev-parse paths are real.
Subagent replies are scripted by ``StubSpawner`` per (role, iteration).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import textwrap
from collections.abc import Callable
from dataclasses import dataclass, field, fields
from pathlib import Path

import pytest

from conduct import conductor
from conduct.conductor import (
    ConductOptions,
    SpawnRequest,
    _repo_default_test_cmd,
    _state_path,
    abort_run,
    conduct,
    default_lint_check,
    delegation_unavailable_result,
    detect_lint_command,
    pause_phase,
)
from conduct.lock import StateLock
from conduct.marker import compute_plan_hash, marker_is_stale, write_marker
from conduct.runner import (
    TestResult as _TestResult,
)  # rename — pytest tries to collect any class named Test*

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, text=True, check=check
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """Real git repo with one initial commit so HEAD is valid."""
    _git(["init", "-q"], tmp_path)
    _git(["config", "user.email", "harness@test"], tmp_path)
    _git(["config", "user.name", "Harness"], tmp_path)
    _git(["config", "commit.gpgsign", "false"], tmp_path)
    (tmp_path / "README.md").write_text("seed\n")
    _git(["add", "README.md"], tmp_path)
    _git(["commit", "-q", "-m", "seed"], tmp_path)
    return tmp_path


def _scratch_plan(repo: Path, body: str) -> Path:
    plans_dir = repo / "docs" / "dev_plans"
    plans_dir.mkdir(parents=True)
    plan = plans_dir / "20260422-scratch.md"
    plan.write_text(textwrap.dedent(body))
    write_marker(plan)
    return plan


def _state_file(repo: Path, plan: Path) -> Path:
    return _state_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )


def _legacy_shared_state_file(repo: Path, plan: Path) -> Path:
    try:
        rel_plan = plan.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        rel_plan = plan.resolve().as_posix()
    digest = __import__("hashlib").sha1(rel_plan.encode("utf-8")).hexdigest()[:12]
    return repo / ".conduct" / f"state-{plan.stem}-{digest}.json"


PLAN_ONE_PHASE = """\
# Scratch
## Implementation Checklist

### Phase 1: Add a file

**Impl files:** src/a.py
**Test files:** tests/test_a.py
**Test command:** `true`

- [ ] do it
"""

PLAN_TWO_PHASES = """\
# Scratch
## Implementation Checklist

### Phase 1: First

**Impl files:** src/a.py
**Test files:** tests/test_a.py
**Test command:** `true`

- [ ] one

### Phase 2: Second

**Impl files:** src/b.py
**Test files:** tests/test_b.py
**Test command:** `true`

- [ ] two
"""

PLAN_NO_TEST_CMD = """\
# Scratch
## Implementation Checklist

### Phase 1: No test command

**Impl files:** src/a.py
**Test files:** tests/test_a.py

- [ ] do it
"""

PLAN_WITH_VALIDATION = """\
# Scratch
## Implementation Checklist

### Phase 1: Validate after tests

**Impl files:** src/a.py
**Test files:** tests/test_a.py
**Test command:** `true`
**Validation cmd:** `python scripts/validate.py`

- [ ] do it
"""

PLAN_VALIDATION_ONLY = """\
# Scratch
## Implementation Checklist

### Phase 1: Validate without tests

**Impl files:** src/a.py
**Test files:** tests/test_a.py
**Validation cmd:** `python scripts/validate.py`

- [ ] do it
"""

PLAN_NO_SLOTS = """\
# Scratch
## Implementation Checklist

### Phase 1: Slotless

- [ ] do it
"""


# ---------------------------------------------------------------------------
# Stub spawner
# ---------------------------------------------------------------------------


def _impl_report(iteration: int, files: list[str], **flags: object) -> str:
    """A valid implementer JSON report wrapped in the trailing fence."""
    payload = {
        "role": "implementer",
        "phase_position": 0,
        "phase_label": "1",
        "iteration": iteration,
        "files_changed": files,
        "summary": "stub",
        "flags": {
            "blocked": False,
            "test_contract_mismatch": False,
            "explanation": None,
            "needs_test_coverage": [],
            **flags,
        },
    }
    return f"prose\n```json\n{json.dumps(payload)}\n```"


def _test_report() -> str:
    payload = {
        "role": "test-writer",
        "phase_position": 0,
        "phase_label": "1",
        "iteration": 0,
        "test_files_added": ["tests/test_a.py"],
        "test_commands": ["true"],
        "coverage_summary": "stub",
        "flags": {"blocked": False, "needs_impl_clarification": None},
    }
    return f"```json\n{json.dumps(payload)}\n```"


@dataclass
class StubSpawner:
    """Scripts subagent replies and stages files on the implementer's behalf.

    Each (role, iteration) key maps to a callable that:
      - takes the SpawnRequest + the repo path
      - performs whatever filesystem mutation a real subagent would have done
        (e.g. write source files, ``git add`` them)
      - returns the raw text the subagent would have printed
    """

    repo: Path
    scripts: dict[tuple[str, int], Callable[[SpawnRequest, Path], str]] = field(
        default_factory=dict
    )
    calls: list[SpawnRequest] = field(default_factory=list)
    rendered_prompts: list[str] = field(default_factory=list)

    def script(
        self, role: str, iteration: int, fn: Callable[[SpawnRequest, Path], str]
    ) -> None:
        self.scripts[(role, iteration)] = fn

    def __call__(self, req: SpawnRequest) -> str:
        self.calls.append(req)
        # Synthesise the rendered prompt the way a real conductor would, so
        # the context-isolation test can grep for sentinels across all fields.
        rendered = "\n".join(
            [
                f"role={req.role}",
                f"plan={req.plan_path}",
                f"iteration={req.iteration}",
                f"base={req.base_sha}",
                f"prior_diff={req.prior_diff}",
                f"test_failures={req.test_failures}",
            ]
        )
        self.rendered_prompts.append(rendered)
        key = (req.role, req.iteration)
        if key not in self.scripts:
            raise AssertionError(f"no scripted reply for {key}")
        return self.scripts[key](req, self.repo)


def _stage(repo: Path, path: str, content: str) -> None:
    full = repo / path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content)
    _git(["add", path], repo)


# ---------------------------------------------------------------------------
# Test runner stub
# ---------------------------------------------------------------------------


@dataclass
class StubTestRunner:
    """Returns scripted _TestResult per call. Runs out of script → assertion."""

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


def _failing(msg: str = "AssertionError: 1 != 2") -> _TestResult:
    return _TestResult(
        returncode=1, output=msg + "\n", timed_out=False, duration_seconds=0.01
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_happy_path_single_phase_commits_and_hands_back(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (
            _stage(r, "src/a.py", "x = 1\n"),
            _impl_report(0, ["src/a.py"]),
        )[1],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
        )
    )

    assert result.status == "awaiting_user"
    assert "Phase 1" in result.summary
    assert result.next_command and "--resume" in result.next_command

    log = _git(["log", "--oneline"], repo).stdout
    assert "conduct: phase 1 — Add a file" in log
    state = json.loads(_state_file(repo, plan).read_text())
    assert state["completed_phases"][0]["tests"] == "passed"
    assert state["completed_phases"][0]["iterations"] == 0


def test_multi_phase_via_resume_advances_one_phase_at_a_time(repo):
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)
    spawner = StubSpawner(repo)
    # Phase 1
    spawner.script(
        "implementer",
        0,
        lambda req, r: (
            _stage(r, "src/a.py", "x=1\n")
            if req.phase_label == "1"
            else _stage(r, "src/b.py", "y=2\n"),
            _impl_report(0, [f"src/{'a' if req.phase_label == '1' else 'b'}.py"]),
        )[1],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing(), _passing()])

    first = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert first.status == "awaiting_user"
    assert len(first.state["completed_phases"]) == 1

    second = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            resume=True,
        )
    )
    assert second.status == "awaiting_user"
    assert len(second.state["completed_phases"]) == 2
    assert [p["label"] for p in second.state["completed_phases"]] == ["1", "2"]


def test_state_file_id_disambiguates_same_basename_plans(repo):
    plan_a = _scratch_plan(repo, PLAN_ONE_PHASE)
    other_dir = repo / "tmp"
    other_dir.mkdir()
    plan_b = other_dir / plan_a.name
    plan_b.write_text(textwrap.dedent(PLAN_ONE_PHASE))
    write_marker(plan_b)

    assert _state_file(repo, plan_a) != _state_file(repo, plan_b)


def test_existing_state_requires_explicit_resume(repo):
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)
    first_spawner = StubSpawner(repo)
    first_spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    first_spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    first = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=first_spawner, test_runner=runner
        )
    )
    assert first.status == "awaiting_user"

    second_spawner = StubSpawner(repo)
    second = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=second_spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
        )
    )
    assert second.status == "awaiting_user"
    assert second.next_command == f"Run: /conduct --resume {plan}"
    assert len(second.state["completed_phases"]) == 1
    assert second_spawner.calls == []
    log = _git(["log", "--oneline"], repo).stdout.splitlines()
    assert sum("conduct: phase" in line for line in log) == 1


def test_assertion_failure_respawns_implementer_and_passes_on_iteration_1(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def first_attempt(req, r):
        _stage(r, "src/a.py", "buggy=1\n")
        return _impl_report(0, ["src/a.py"])

    def second_attempt(req, r):
        # Conductor must have reset the index and provided the prior diff.
        assert "buggy" in req.prior_diff
        assert "AssertionError" in req.test_failures
        _stage(r, "src/a.py", "fixed=1\n")
        return _impl_report(1, ["src/a.py"])

    spawner.script("implementer", 0, first_attempt)
    spawner.script("implementer", 1, second_attempt)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_failing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert result.state["iteration_count"] == 1
    impl_calls = [c for c in spawner.calls if c.role == "implementer"]
    assert [c.iteration for c in impl_calls] == [0, 1]


def test_failure_summaries_are_redacted_before_respawn(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def first_attempt(req, r):
        _stage(r, "src/a.py", "buggy=1\n")
        return _impl_report(0, ["src/a.py"])

    def second_attempt(req, r):
        assert "AssertionError" in req.test_failures
        assert "token=[REDACTED]" in req.test_failures
        assert "token=abc123" not in req.test_failures
        _stage(r, "src/a.py", "fixed=1\n")
        return _impl_report(1, ["src/a.py"])

    spawner.script("implementer", 0, first_attempt)
    spawner.script("implementer", 1, second_attempt)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_failing("AssertionError token=abc123"), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"


def test_blocked_implementer_report_stops_before_tests_or_commit(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def blocked_impl(req, r):
        _stage(r, "src/a.py", "partial=1\n")
        return _impl_report(
            0,
            ["src/a.py"],
            blocked=True,
            explanation="missing API contract",
        )

    spawner.script("implementer", 0, blocked_impl)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "blocked"
    assert "missing API contract" in result.summary
    assert runner.calls == []
    log = _git(["log", "--oneline"], repo).stdout
    assert "conduct: phase 1" not in log


def test_test_writer_clarification_blocks_before_commit(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )

    def clarifying_test_writer(req, r):
        payload = {
            "role": "test-writer",
            "phase_position": 0,
            "phase_label": "1",
            "iteration": 0,
            "test_files_added": ["tests/test_a.py"],
            "test_commands": ["true"],
            "coverage_summary": "need clarification",
            "flags": {
                "blocked": False,
                "needs_impl_clarification": "error path still unspecified",
            },
        }
        return f"```json\n{json.dumps(payload)}\n```"

    spawner.script("test-writer", 0, clarifying_test_writer)
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "blocked"
    assert "error path still unspecified" in result.summary
    assert runner.calls == []
    log = _git(["log", "--oneline"], repo).stdout
    assert "conduct: phase 1" not in log


def test_test_contract_mismatch_routes_iteration_1_to_test_writer(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def impl_first(req, r):
        _stage(r, "src/a.py", "x=1\n")
        return _impl_report(
            0, ["src/a.py"], test_contract_mismatch=True, explanation="tests wrong"
        )

    def test_writer_second(req, r):
        # Conductor flipped to test-writer because of the mismatch flag.
        _stage(r, "tests/test_a.py", "def test_a(): assert True\n")
        payload = {
            "role": "test-writer",
            "phase_position": 0,
            "phase_label": "1",
            "iteration": 1,
            "test_files_added": ["tests/test_a.py"],
            "test_commands": ["true"],
            "coverage_summary": "fixed",
            "flags": {"blocked": False, "needs_impl_clarification": None},
        }
        return f"```json\n{json.dumps(payload)}\n```"

    spawner.script("implementer", 0, impl_first)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    spawner.script("test-writer", 1, test_writer_second)
    runner = StubTestRunner(queue=[_failing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    # Iteration-1 spawn was the test-writer, not the implementer.
    iter1 = [c for c in spawner.calls if c.iteration == 1]
    assert len(iter1) == 1
    assert iter1[0].role == "test-writer"


def test_test_writer_retry_preserves_prior_implementation_changes(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def impl_first(req, r):
        _stage(r, "src/a.py", "impl=1\n")
        return _impl_report(
            0, ["src/a.py"], test_contract_mismatch=True, explanation="tests wrong"
        )

    def test_writer_second(req, r):
        assert "impl=1" in req.prior_diff
        _stage(r, "tests/test_a.py", "def test_a(): assert True\n")
        payload = {
            "role": "test-writer",
            "phase_position": 0,
            "phase_label": "1",
            "iteration": 1,
            "test_files_added": ["tests/test_a.py"],
            "test_commands": ["true"],
            "coverage_summary": "fixed",
            "flags": {"blocked": False, "needs_impl_clarification": None},
        }
        return f"```json\n{json.dumps(payload)}\n```"

    spawner.script("implementer", 0, impl_first)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    spawner.script("test-writer", 1, test_writer_second)
    runner = StubTestRunner(queue=[_failing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    show = _git(["show", "--stat", "--name-only", "--format=%B", "HEAD"], repo).stdout
    assert "src/a.py" in show
    assert "tests/test_a.py" in show


def test_fix_loop_cap_blocks_after_three_iterations(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def attempt(req, r):
        _stage(r, "src/a.py", f"v={req.iteration}\n")
        return _impl_report(req.iteration, ["src/a.py"])

    for i in range(4):
        spawner.script("implementer", i, attempt)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_failing(), _failing(), _failing(), _failing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            max_iterations=3,
            stall_threshold=99,
        )
    )
    assert result.status == "blocked"
    assert result.state["blocker"] == "max_iterations exceeded (legacy)"
    # 4 implementer spawns: iteration 0, 1, 2, 3 — the 4th increments past cap.
    impl_iters = [c.iteration for c in spawner.calls if c.role == "implementer"]
    assert impl_iters == [0, 1, 2, 3]


def test_preflight_lint_failure_hard_stops_before_any_spawn(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    runner = StubTestRunner()

    def lint_fails():
        return "src/foo.py:1: E501 line too long"

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            lint_check=lint_fails,
        )
    )
    assert result.status == "preflight_fail"
    assert "lint" in result.diagnostic.lower()
    assert spawner.calls == []
    assert runner.calls == []


def test_missing_test_command_warns_and_completes_phase(repo):
    plan = _scratch_plan(repo, PLAN_NO_TEST_CMD)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner()  # never called

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert "no test command" in result.summary
    assert runner.calls == []
    log = _git(["log", "--oneline"], repo).stdout
    assert "phase 1" in log


def test_validation_runs_even_when_no_test_command_is_declared(repo):
    plan = _scratch_plan(repo, PLAN_VALIDATION_ONLY)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert "no test command" in result.summary
    assert "validation passed" in result.summary
    assert runner.calls == [("python scripts/validate.py", 300.0)]


def test_validation_failure_without_test_command_hands_back_before_commit(repo):
    plan = _scratch_plan(repo, PLAN_VALIDATION_ONLY)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_failing("validation failed")])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert result.summary == "Phase 1 validation failed"
    log = _git(["log", "--oneline"], repo).stdout
    assert "conduct: phase 1" not in log


def test_validation_failure_diagnostic_is_redacted(repo):
    plan = _scratch_plan(repo, PLAN_VALIDATION_ONLY)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_failing("Authorization: Bearer supersecret-token")])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert "[REDACTED]" in (result.diagnostic or "")
    assert "supersecret-token" not in (result.diagnostic or "")


def test_precommit_hook_failure_routes_to_fix_loop(repo):
    """Install a hook that fails the first commit attempt and passes the second.

    The conductor must treat the first failure as a fix-loop iteration (not a
    hard error), respawn the implementer with the hook output as test_failures,
    and complete the phase on the next attempt.
    """
    hooks_dir = repo / ".git" / "hooks"
    counter = repo / ".hook-counter"
    counter.write_text("0\n")
    hook = hooks_dir / "pre-commit"
    hook.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            n=$(cat {counter})
            echo $((n+1)) > {counter}
            if [ "$n" = "0" ]; then
              echo "hook says no" >&2
              exit 1
            fi
            exit 0
            """
        )
    )
    hook.chmod(0o755)

    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def attempt(req, r):
        _stage(r, "src/a.py", f"v={req.iteration}\n")
        return _impl_report(req.iteration, ["src/a.py"])

    spawner.script("implementer", 0, attempt)
    spawner.script("implementer", 1, attempt)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert result.state["iteration_count"] == 1
    log = _git(["log", "--oneline"], repo).stdout
    assert "phase 1" in log
    impl_calls = [c for c in spawner.calls if c.role == "implementer"]
    assert any("hook says no" in c.test_failures for c in impl_calls)


def test_boundary_commit_failure_diagnostic_is_redacted(repo):
    hooks_dir = repo / ".git" / "hooks"
    hook = hooks_dir / "pre-commit"
    hook.write_text(
        textwrap.dedent(
            """\
            #!/bin/sh
            echo "Authorization: Bearer hook-secret" >&2
            exit 1
            """
        )
    )
    hook.chmod(0o755)

    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def attempt(req, r):
        _stage(r, "src/a.py", f"v={req.iteration}\n")
        return _impl_report(req.iteration, ["src/a.py"])

    for i in range(4):
        spawner.script("implementer", i, attempt)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            max_iterations=3,
        )
    )
    assert result.status == "blocked"
    assert "[REDACTED]" in (result.diagnostic or "")
    assert "hook-secret" not in (result.diagnostic or "")


def test_precommit_hook_restage_retry_succeeds_without_respawn(repo):
    hooks_dir = repo / ".git" / "hooks"
    counter = repo / ".hook-counter"
    counter.write_text("0\n")
    hook = hooks_dir / "pre-commit"
    hook.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            n=$(cat {counter})
            echo $((n+1)) > {counter}
            if [ "$n" = "0" ]; then
              printf '# hook formatted\\n' >> src/a.py
              echo "formatter changed files" >&2
              exit 1
            fi
            exit 0
            """
        )
    )
    hook.chmod(0o755)

    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert result.state["iteration_count"] == 0
    assert "pre-commit hook modified files; re-staged and retrying" in result.summary
    assert (
        len([c for c in spawner.calls if c.role == "implementer" and c.iteration > 0])
        == 0
    )
    assert "# hook formatted" in (repo / "src" / "a.py").read_text()


def test_precommit_hook_does_not_stage_unrelated_tracked_edits(repo):
    _stage(repo, "docs/unrelated.md", "seed\n")
    _git(["commit", "-q", "-m", "seed unrelated"], repo)
    (repo / "docs" / "unrelated.md").write_text("dirty tracked edit\n")

    hooks_dir = repo / ".git" / "hooks"
    counter = repo / ".hook-counter"
    counter.write_text("0\n")
    hook = hooks_dir / "pre-commit"
    hook.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            n=$(cat {counter})
            echo $((n+1)) > {counter}
            if [ "$n" = "0" ]; then
              printf '# hook formatted\\n' >> src/a.py
              echo "formatter changed files" >&2
              exit 1
            fi
            exit 0
            """
        )
    )
    hook.chmod(0o755)

    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert "outside the staged set" in result.summary
    log = _git(["log", "--oneline"], repo).stdout
    assert "conduct: phase 1" not in log
    assert (repo / "docs" / "unrelated.md").read_text() == "dirty tracked edit\n"


def test_pause_phase_stashes_and_marks_state(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    # Pre-create state so pause has something to mark.
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file(repo, plan)
    state_file.write_text(
        json.dumps({"plan_path": str(plan), "current_phase_title": "Add a file"})
    )
    # Make a dirty file so stash actually has something to push.
    (repo / "scratch.txt").write_text("wip\n")

    result = pause_phase(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert result.status == "paused"
    state = json.loads(state_file.read_text())
    assert state["status"] == "paused"
    assert state["paused_stash_rev"]
    stash = _git(["stash", "list"], repo).stdout
    assert "conduct-pause-phase" in stash


def test_resume_restores_paused_stash_before_continuing(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file(repo, plan)
    state_file.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "plan_path": str(plan),
                "plan_content_hash": compute_plan_hash(plan),
                "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
                "phase_index": 0,
                "current_phase_title": "Add a file",
                "completed_phases": [],
                "last_summary": "",
                "iteration_count": 0,
                "status": "running",
                "blocker": None,
                "paused_stash_rev": None,
            }
        )
    )
    (repo / "scratch.txt").write_text("paused work\n")
    paused = pause_phase(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert paused.status == "paused"

    spawner = StubSpawner(repo)

    def impl(req, r):
        assert (r / "scratch.txt").read_text() == "paused work\n"
        _stage(r, "src/a.py", "x=1\n")
        return _impl_report(0, ["src/a.py"])

    spawner.script("implementer", 0, impl)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    resumed = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            resume=True,
        )
    )
    assert resumed.status == "awaiting_user"
    assert (repo / "scratch.txt").read_text() == "paused work\n"
    assert "conduct-pause-phase" not in _git(["stash", "list"], repo).stdout


def test_abort_run_deletes_state_without_touching_tree(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file(repo, plan)
    state_file.write_text("{}")
    (repo / "scratch.txt").write_text("wip\n")

    result = abort_run(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert result.status == "aborted"
    assert not state_file.exists()
    # User's working tree files are preserved — abort only drops state, never
    # runs git reset / clean / stash.
    assert (repo / "scratch.txt").read_text() == "wip\n"
    assert plan.exists()
    stash = _git(["stash", "list"], repo).stdout
    assert "conduct-" not in stash


def test_abort_run_refuses_when_state_lock_held(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file(repo, plan)
    state_file.write_text(
        json.dumps(
            {
                "plan_path": str(plan),
                "plan_content_hash": compute_plan_hash(plan),
                "current_phase_title": "Add a file",
            }
        )
    )
    lock = StateLock(state_file.with_suffix(state_file.suffix + ".lock"))
    lock.acquire()
    try:
        result = abort_run(
            ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
        )
        assert result.status == "blocked"
        assert state_file.exists()
    finally:
        lock.release()


def test_abort_run_does_not_delete_other_plan_state_with_same_basename(repo):
    plan_a = _scratch_plan(repo, PLAN_ONE_PHASE)
    other_dir = repo / "tmp"
    other_dir.mkdir()
    plan_b = other_dir / plan_a.name
    plan_b.write_text(textwrap.dedent(PLAN_ONE_PHASE))
    write_marker(plan_b)

    state_a = _state_file(repo, plan_a)
    state_a.parent.mkdir(parents=True, exist_ok=True)
    state_a.write_text(
        json.dumps(
            {
                "plan_path": str(plan_a),
                "plan_content_hash": compute_plan_hash(plan_a),
                "current_phase_title": "Add a file",
            }
        )
    )

    result = abort_run(
        ConductOptions(plan_path=plan_b, repo_root=repo, spawn=lambda r: "")
    )
    assert result.status == "aborted"
    assert state_a.exists()


def test_abort_run_refuses_symlinked_state_path(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file(repo, plan)
    victim = repo / "victim.txt"
    victim.write_text("keep me\n")
    state_file.symlink_to(victim)

    result = abort_run(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert result.status == "blocked"
    assert victim.read_text() == "keep me\n"
    assert state_file.is_symlink()


def test_conduct_refuses_symlinked_state_path(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file(repo, plan)
    victim = repo / "victim.txt"
    victim.write_text("keep me\n")
    state_file.symlink_to(victim)

    spawner = StubSpawner(repo)
    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=StubTestRunner()
        )
    )
    assert result.status == "preflight_fail"
    assert "unsafe conduct state path" in result.summary
    assert victim.read_text() == "keep me\n"
    assert spawner.calls == []


def test_safe_read_state_text_refuses_symlink(tmp_path):
    state_path = tmp_path / "state.json"
    victim = tmp_path / "victim.json"
    victim.write_text('{"status": "running"}\n')
    state_path.symlink_to(victim)

    with pytest.raises(RuntimeError):
        conductor._safe_read_state_text(state_path)


def test_rogue_commit_detection_does_not_stack_a_second_commit(repo):
    """Subagent commits during its own work; conductor must detect and refuse."""
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)

    def rogue_impl(req, r):
        _stage(r, "src/a.py", "x=1\n")
        # Simulate the prompt-violation: subagent runs git commit itself.
        _git(["commit", "-q", "-m", "rogue subagent commit"], r)
        return _impl_report(0, ["src/a.py"])

    spawner.script("implementer", 0, rogue_impl)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    sha_before = _git(["rev-parse", "HEAD"], repo).stdout.strip()
    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert result.state["completed_phases"][0]["rogue_commit_sha"] is not None
    assert result.state["completed_phases"][0]["commit_sha"] is None
    # Exactly one new commit (the rogue one), not two.
    log = _git(["log", "--oneline"], repo).stdout.splitlines()
    assert "conduct: phase" not in "\n".join(log)
    assert sha_before not in _git(["rev-parse", "HEAD"], repo).stdout.strip()


def test_schema_error_does_not_respawn_and_marks_state_schema_error(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (
            _stage(r, "src/a.py", "x=1\n"),
            "no json fence here, just prose",
        )[1],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner()

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "schema_error"
    # Only one implementer spawn — no respawn after schema error.
    assert (
        len([c for c in spawner.calls if c.role == "implementer" and c.iteration > 0])
        == 0
    )


def test_context_isolation_no_sentinel_leaks_into_rendered_prompts(repo):
    """The conductor must not thread parent-conversation strings into prompts.

    We verify this by setting a sentinel in this test's environment AND in the
    plan file, then asserting the rendered prompts only contain plan content
    (which is permitted) but not any environment / random scope leakage.
    """
    sentinel = "SENTINEL_LEAK_7f3a"
    os.environ["CONDUCT_TEST_SENTINEL"] = sentinel
    try:
        plan = _scratch_plan(repo, PLAN_ONE_PHASE)
        spawner = StubSpawner(repo)
        spawner.script(
            "implementer",
            0,
            lambda req, r: (
                _stage(r, "src/a.py", "x=1\n"),
                _impl_report(0, ["src/a.py"]),
            )[1],
        )
        spawner.script("test-writer", 0, lambda req, r: _test_report())
        runner = StubTestRunner(queue=[_passing()])

        conduct(
            ConductOptions(
                plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
            )
        )
        for prompt in spawner.rendered_prompts:
            assert sentinel not in prompt, "parent context leaked into subagent prompt"
    finally:
        del os.environ["CONDUCT_TEST_SENTINEL"]


def test_resume_across_simulated_restart_picks_up_at_next_phase(repo):
    """Phase 1 completes; we discard the in-process state object and re-invoke.

    The fresh ConductOptions has no in-memory carry-over — the only continuity
    is the on-disk state file. This is the same shape as a process restart.
    """
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)

    def make_spawner():
        s = StubSpawner(repo)
        s.script(
            "implementer",
            0,
            lambda req, r: (
                _stage(r, f"src/{'a' if req.phase_label == '1' else 'b'}.py", "v=1\n"),
                _impl_report(0, [f"src/{'a' if req.phase_label == '1' else 'b'}.py"]),
            )[1],
        )
        s.script("test-writer", 0, lambda req, r: _test_report())
        return s

    runner1 = StubTestRunner(queue=[_passing()])
    r1 = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=make_spawner(), test_runner=runner1
        )
    )
    assert r1.status == "awaiting_user"

    # Simulated restart: brand-new options, brand-new spawner, --resume on.
    runner2 = StubTestRunner(queue=[_passing()])
    r2 = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=make_spawner(),
            test_runner=runner2,
            resume=True,
        )
    )
    assert r2.status == "awaiting_user"
    labels = [p["label"] for p in r2.state["completed_phases"]]
    assert labels == ["1", "2"]


def test_resume_rejects_state_from_different_plan_path(repo):
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)
    other_plan = repo / "tmp" / "20260422-scratch.md"
    other_plan.parent.mkdir(parents=True)
    other_plan.write_text(textwrap.dedent(PLAN_TWO_PHASES))
    write_marker(other_plan)

    state_dir = repo / ".conduct"
    state_dir.mkdir()
    _state_file(repo, plan).write_text(
        json.dumps(
            {
                "plan_path": str(other_plan),
                "plan_content_hash": compute_plan_hash(other_plan),
                "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
                "phase_index": 0,
                "current_phase_title": "",
                "completed_phases": [],
                "last_summary": "",
                "iteration_count": 0,
                "status": "awaiting_user",
                "blocker": None,
            }
        )
    )

    spawner = StubSpawner(repo)
    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=StubTestRunner()
        )
    )
    assert result.status == "preflight_fail"
    assert "state does not match current reviewed plan" in result.summary
    assert spawner.calls == []


def test_resume_after_manual_review_resyncs_state_hash(repo, capsys):
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)

    def make_spawner():
        spawner = StubSpawner(repo)
        spawner.script(
            "implementer",
            0,
            lambda req, r: (
                _stage(r, f"src/{'a' if req.phase_label == '1' else 'b'}.py", "x=1\n"),
                _impl_report(0, [f"src/{'a' if req.phase_label == '1' else 'b'}.py"]),
            )[1],
        )
        spawner.script("test-writer", 0, lambda req, r: _test_report())
        return spawner

    first = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=make_spawner(),
            test_runner=StubTestRunner(queue=[_passing()]),
        )
    )
    assert first.status == "awaiting_user"
    pre_state = json.loads(_state_file(repo, plan).read_text())
    pre_hash = pre_state["plan_content_hash"]

    plan.write_text(
        plan.read_text().replace("### Phase 2: Second", "### Phase 2: Second reviewed")
    )
    write_marker(plan)
    assert marker_is_stale(plan) is False
    assert compute_plan_hash(plan) != pre_hash

    second_spawner = make_spawner()
    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=second_spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            resume=True,
        )
    )
    assert result.status == "awaiting_user"
    post_state = json.loads(_state_file(repo, plan).read_text())
    assert post_state["plan_content_hash"] == compute_plan_hash(plan)
    assert post_state["plan_content_hash"] != pre_hash
    assert [p["label"] for p in result.state["completed_phases"]] == ["1", "2"]
    assert second_spawner.calls
    assert "auto-refreshed on resume" not in capsys.readouterr().err


def test_resume_after_above_marker_edit_refreshes_marker_and_resyncs_state_hash(
    repo, capsys
):
    """End-to-end: complete phase 1, amend the contract above the marker,
    then resume without tripping Codex's active plan_content_hash check.
    """
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)

    def make_spawner():
        spawner = StubSpawner(repo)
        spawner.script(
            "implementer",
            0,
            lambda req, r: (
                _stage(r, f"src/{'a' if req.phase_label == '1' else 'b'}.py", "x=1\n"),
                _impl_report(0, [f"src/{'a' if req.phase_label == '1' else 'b'}.py"]),
            )[1],
        )
        spawner.script("test-writer", 0, lambda req, r: _test_report())
        return spawner

    first = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=make_spawner(),
            test_runner=StubTestRunner(queue=[_passing()]),
        )
    )
    assert first.status == "awaiting_user"
    pre_state = json.loads(_state_file(repo, plan).read_text())
    pre_hash = pre_state["plan_content_hash"]

    plan.write_text(
        plan.read_text().replace("### Phase 2: Second", "### Phase 2: Second amended")
    )
    new_plan_hash = compute_plan_hash(plan)
    assert new_plan_hash != pre_hash
    assert marker_is_stale(plan) is True

    second_spawner = make_spawner()
    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=second_spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
            resume=True,
        )
    )

    assert result.status == "awaiting_user"
    post_state = json.loads(_state_file(repo, plan).read_text())
    assert post_state["plan_content_hash"] == compute_plan_hash(plan)
    assert post_state["plan_content_hash"] != pre_hash
    assert marker_is_stale(plan) is False
    assert [p["label"] for p in result.state["completed_phases"]] == ["1", "2"]
    assert second_spawner.calls
    assert "auto-refreshed on resume" in capsys.readouterr().err


def test_resume_blocks_when_reviewed_edit_changes_completed_phase_prefix(repo):
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (
            _stage(r, "src/a.py", "x=1\n"),
            _impl_report(0, ["src/a.py"]),
        )[1],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())

    first = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
        )
    )
    assert first.status == "awaiting_user"

    plan.write_text(
        plan.read_text().replace(
            "### Phase 1: First",
            "### Phase 0: Inserted\n\n- [ ] new task\n\n### Phase 1: First",
            1,
        )
    )
    write_marker(plan)

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(),
            resume=True,
        )
    )

    assert result.status == "blocked"
    assert "completed phase prefix" in result.summary
    assert "position 1" in (result.diagnostic or "")


# ---------------------------------------------------------------------------
# C1: repo-default test-cmd fallback (SKILL.md Step 5)
# ---------------------------------------------------------------------------


def test_repo_default_test_cmd_returns_none_for_bare_repo(tmp_path):
    assert _repo_default_test_cmd(tmp_path) is None


def test_repo_default_test_cmd_picks_npm_when_package_json_has_scripts_test(tmp_path):
    (tmp_path / "package.json").write_text('{"scripts": {"test": "jest"}}\n')
    assert _repo_default_test_cmd(tmp_path) == "npm test"


def test_repo_default_test_cmd_skips_package_json_without_scripts_test(tmp_path):
    (tmp_path / "package.json").write_text('{"name": "x"}\n')
    assert _repo_default_test_cmd(tmp_path) is None


def test_repo_default_test_cmd_picks_pytest_when_pyproject_has_pytest_section(tmp_path):
    (tmp_path / "pyproject.toml").write_text(
        "[tool.pytest.ini_options]\ntestpaths = ['tests']\n"
    )
    assert _repo_default_test_cmd(tmp_path) == "uvx pytest"


def test_repo_default_test_cmd_picks_make_test_target(tmp_path):
    (tmp_path / "Makefile").write_text("build:\n\techo build\ntest:\n\tpytest -q\n")
    assert _repo_default_test_cmd(tmp_path) == "make test"


def test_repo_default_test_cmd_ignores_indented_make_test_target(tmp_path):
    (tmp_path / "Makefile").write_text("build:\n\ttest:\n\t\tpytest -q\n")
    assert _repo_default_test_cmd(tmp_path) is None


def test_repo_default_test_cmd_probe_order_prefers_package_json(tmp_path):
    """All three present → npm wins per SKILL.md Step 5."""
    (tmp_path / "package.json").write_text('{"scripts": {"test": "jest"}}\n')
    (tmp_path / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    (tmp_path / "Makefile").write_text("test:\n\tpytest\n")
    assert _repo_default_test_cmd(tmp_path) == "npm test"


def test_resume_base_sha_is_cleared_after_phase_commits(repo):
    """C2 regression: leaving resume_base_sha set across phases would make a
    clean phase 2 trip the rogue-commit check on a multi-phase resumed run.

    Reproduces the failure shape directly: resume on a 2-phase plan with phase
    1 already marked complete in state, run phase 2, assert state.resume_base_sha
    is gone afterwards (so any subsequent phase falls through to last-completed
    commit_sha as baseline).
    """
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)

    # Simulate phase 1 having already shipped in a prior run by committing it
    # here and pre-populating the state file the way conduct() would have.
    _stage(repo, "src/a.py", "x=1\n")
    _git(["commit", "-q", "-m", "conduct: phase 1 — First"], repo)
    phase1_sha = _git(["rev-parse", "HEAD"], repo).stdout.strip()

    state_dir = repo / ".conduct"
    state_dir.mkdir()
    _state_file(repo, plan).write_text(
        json.dumps(
            {
                "plan_path": str(plan),
                "plan_content_hash": compute_plan_hash(plan),
                "base_sha": phase1_sha,  # arbitrary prior baseline
                "completed_phases": [
                    {
                        "index": 0,
                        "label": "1",
                        "title": "First",
                        "commit_sha": phase1_sha,
                        "tests": "passed",
                        "iterations": 0,
                    }
                ],
                "iteration_count": 0,
                "status": "awaiting_user",
                "blocker": None,
            }
        )
    )

    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/b.py", "y=2\n"), _impl_report(0, ["src/b.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            resume=True,
        )
    )
    assert result.status == "awaiting_user", result.summary
    assert "resume_base_sha" not in result.state
    # Phase 2 was committed normally, no rogue-commit annotation.
    completed = result.state["completed_phases"]
    assert [p["label"] for p in completed] == ["1", "2"]
    assert completed[1]["commit_sha"] is not None
    assert completed[1].get("rogue_commit_sha") is None


def test_hook_retry_respects_blocked_respawn_report(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    hooks_dir = repo / ".git" / "hooks"
    hook = hooks_dir / "pre-commit"
    hook.write_text("#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
    hook.chmod(0o755)

    spawner = StubSpawner(repo)

    def initial_impl(req, r):
        _stage(r, "src/a.py", "x=1\n")
        return _impl_report(0, ["src/a.py"])

    def blocked_retry(req, r):
        assert "hook says no" in req.test_failures
        _stage(r, "src/a.py", "x=2\n")
        return _impl_report(
            1, ["src/a.py"], blocked=True, explanation="manual migration required"
        )

    spawner.script("implementer", 0, initial_impl)
    spawner.script("implementer", 1, blocked_retry)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "blocked"
    assert "manual migration required" in result.summary
    log = _git(["log", "--oneline"], repo).stdout
    assert "conduct: phase 1" not in log


# ---------------------------------------------------------------------------
# C3: default_lint_check probe (SKILL.md Preflight Step 3)
# ---------------------------------------------------------------------------


def _which_stub(present: set[str]):
    """Returns a shutil.which replacement that reports only ``present``."""
    return lambda name: f"/usr/bin/{name}" if name in present else None


def test_detect_lint_command_returns_none_when_nothing_available(tmp_path, monkeypatch):
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub(set()))
    assert detect_lint_command(tmp_path) is None


def test_detect_lint_command_prefers_pre_commit(tmp_path, monkeypatch):
    (tmp_path / ".pre-commit-config.yaml").write_text("repos: []\n")
    (tmp_path / "Makefile").write_text("lint:\n\tpython -m flake8\n")
    (tmp_path / "package.json").write_text('{"scripts": {"lint": "eslint ."}}\n')
    monkeypatch.setattr(
        "conduct.conductor.shutil.which",
        _which_stub({"pre-commit", "make", "npm", "ruff"}),
    )
    assert detect_lint_command(tmp_path) == ["pre-commit", "run", "--all-files"]


def test_detect_lint_command_skips_pre_commit_when_binary_missing(
    tmp_path, monkeypatch
):
    (tmp_path / ".pre-commit-config.yaml").write_text("repos: []\n")
    (tmp_path / "Makefile").write_text("lint:\n\tflake8\n")
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"make"}))
    assert detect_lint_command(tmp_path) == ["make", "lint"]


def test_detect_lint_command_ignores_indented_make_lint_target(tmp_path, monkeypatch):
    (tmp_path / "Makefile").write_text("build:\n\tlint:\n\t\tflake8\n")
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"make"}))
    assert detect_lint_command(tmp_path) is None


def test_detect_lint_command_falls_through_to_npm_run_lint(tmp_path, monkeypatch):
    (tmp_path / "package.json").write_text('{"scripts": {"lint": "eslint ."}}\n')
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"npm"}))
    assert detect_lint_command(tmp_path) == ["npm", "run", "lint"]


def test_detect_lint_command_falls_through_to_ruff_for_python_repo(
    tmp_path, monkeypatch
):
    (tmp_path / "pyproject.toml").write_text("[project]\nname='x'\n")
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"ruff"}))
    assert detect_lint_command(tmp_path) == ["ruff", "check", "."]


def test_detect_lint_command_falls_through_to_ruff_for_nested_python_repo(
    tmp_path, monkeypatch
):
    nested = tmp_path / ".codex" / "skills" / "conduct"
    nested.mkdir(parents=True)
    (nested / "conductor.py").write_text("print('x')\n")
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"ruff"}))
    assert detect_lint_command(tmp_path) == ["ruff", "check", "."]


def test_detect_lint_command_skips_ruff_when_no_python_signal(tmp_path, monkeypatch):
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"ruff"}))
    assert detect_lint_command(tmp_path) is None


def test_default_lint_check_returns_none_when_no_tool_available(tmp_path, monkeypatch):
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub(set()))
    assert default_lint_check(tmp_path) is None


def test_default_lint_check_runs_detected_command_and_reports_failure(
    tmp_path, monkeypatch
):
    """Use a Makefile + real ``make`` (the test harness already depends on
    Unix make presence for git, so this is portable). The lint target exits 1
    with an identifiable diagnostic that we expect surfaced in the result.
    """
    if shutil.which("make") is None:
        pytest.skip("make not available")
    (tmp_path / "Makefile").write_text(
        "lint:\n\t@echo 'fake lint failure: line too long'; exit 1\n"
    )
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"make"}))
    diag = default_lint_check(tmp_path)
    assert diag is not None
    assert "make lint" in diag
    assert "fake lint failure" in diag


def test_default_lint_check_returns_none_on_passing_check(tmp_path, monkeypatch):
    if shutil.which("make") is None:
        pytest.skip("make not available")
    (tmp_path / "Makefile").write_text("lint:\n\t@true\n")
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"make"}))
    assert default_lint_check(tmp_path) is None


def test_run_preflight_does_not_invoke_default_lint_check_implicitly(repo, monkeypatch):
    """Security hardening: preflight should not execute repo-defined lint
    entrypoints unless the caller explicitly opts in via lint_check.
    """
    if shutil.which("make") is None:
        pytest.skip("make not available")
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    (repo / "Makefile").write_text(
        "lint:\n\t@echo 'preflight diagnostic seeded'; exit 1\n"
    )
    monkeypatch.setattr("conduct.conductor.shutil.which", _which_stub({"make"}))
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert spawner.calls


def test_phase_with_no_slot_falls_back_to_repo_default(repo):
    """End-to-end: phase has no Test command, repo has pyproject pytest section.

    The conductor must resolve to ``uvx pytest`` and call the test runner with
    that command. We stub the runner to record the call, so the test does not
    actually invoke pytest.
    """
    plan = _scratch_plan(repo, PLAN_NO_TEST_CMD)
    (repo / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert runner.calls and runner.calls[0][0] == "uvx pytest"


def test_plan_with_no_slots_warns_about_degraded_mode(repo):
    plan = _scratch_plan(repo, PLAN_NO_SLOTS)
    (repo / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert "running in degraded mode" in result.summary
    assert runner.calls and runner.calls[0][0] == "uvx pytest"


def test_validation_failure_hands_back_without_commit(repo):
    plan = _scratch_plan(repo, PLAN_WITH_VALIDATION)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing(), _failing("validation drift detected")])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert result.summary == "Phase 1 validation failed"
    assert "validation drift detected" in result.diagnostic
    log = _git(["log", "--oneline"], repo).stdout
    assert "conduct: phase 1" not in log


def test_validation_pass_adds_warning_before_commit(repo):
    plan = _scratch_plan(repo, PLAN_WITH_VALIDATION)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"
    assert [call[0] for call in runner.calls] == ["true", "python scripts/validate.py"]
    assert "validation passed" in result.summary


def test_state_file_includes_documented_contract_keys(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (
            _stage(r, "src/a.py", "x = 1\n"),
            _impl_report(0, ["src/a.py"]),
        )[1],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user"

    state_path = _state_file(repo, plan)
    state = json.loads(state_path.read_text())
    assert {
        "schema_version",
        "plan_path",
        "plan_content_hash",
        "base_sha",
        "phase_index",
        "current_phase_title",
        "completed_phases",
        "last_summary",
        "iteration_count",
        "status",
        "blocker",
        "paused_stash_rev",
    }.issubset(state)
    assert state["schema_version"] == 2
    assert state["plan_content_hash"] == compute_plan_hash(plan)
    assert state["last_summary"] == result.summary


def test_resume_migrates_legacy_state_file_without_schema_version(repo):
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)
    state_path = _state_file(repo, plan)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(
        json.dumps(
            {
                "plan_path": str(plan),
                "plan_content_hash": compute_plan_hash(plan),
                "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
                "phase_index": 1,
                "current_phase_title": "First",
                "completed_phases": [
                    {
                        "index": 0,
                        "label": "1",
                        "title": "First",
                        "commit_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
                        "tests": "passed",
                        "iterations": 0,
                    }
                ],
                "last_summary": "",
                "iteration_count": 0,
                "status": "awaiting_user",
                "blocker": None,
            }
        )
    )
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/b.py", "y=2\n"), _impl_report(0, ["src/b.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=runner,
            resume=True,
        )
    )
    assert result.status == "awaiting_user"
    migrated = json.loads(state_path.read_text())
    assert migrated["schema_version"] == 2
    assert "paused_stash_rev" in migrated


def test_resume_blocks_legacy_paused_state_without_stash_metadata(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_path = _state_file(repo, plan)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(
        json.dumps(
            {
                "plan_path": str(plan),
                "plan_content_hash": compute_plan_hash(plan),
                "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
                "phase_index": 0,
                "current_phase_title": "Add a file",
                "completed_phases": [],
                "last_summary": "",
                "iteration_count": 0,
                "status": "paused",
                "blocker": None,
            }
        )
    )
    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=StubSpawner(repo),
            test_runner=StubTestRunner(),
            resume=True,
        )
    )
    assert result.status == "blocked"
    assert "missing stash metadata" in result.summary


def test_delegation_unavailable_result_hard_stops_with_clear_message():
    plan = Path("docs/dev_plans/example.md")
    result = delegation_unavailable_result(plan)
    assert result.status == "preflight_fail"
    assert "Delegated subagents unavailable" in result.diagnostic
    assert str(plan) in result.diagnostic


def _check_iteration_bound(state: dict, opts: ConductOptions, signature: str):
    helper = getattr(conductor, "_check_iteration_bound", None)
    if helper is None:
        pytest.fail("conductor._check_iteration_bound is missing")
    return helper(state, opts, signature)


def _phase1_opts(repo: Path, plan: Path, **overrides) -> ConductOptions:
    kwargs = {
        "plan_path": plan,
        "repo_root": repo,
        "spawn": StubSpawner(repo),
        "test_runner": StubTestRunner(),
        **overrides,
    }
    return ConductOptions(**kwargs)


def _bound_state() -> dict:
    return {
        "schema_version": 2,
        "plan_path": "docs/dev_plans/example.md",
        "plan_content_hash": "a" * 40,
        "base_sha": "b" * 40,
        "phase_index": 0,
        "current_phase_title": "Add a file",
        "completed_phases": [],
        "last_summary": "",
        "iteration_count": 0,
        "status": "running",
        "blocker": None,
        "paused_stash_rev": None,
        "stall_signatures": [],
        "stall_count": 0,
    }


def test_conduct_result_shape_includes_next_action_and_request():
    names = {field.name for field in fields(conductor.ConductResult)}
    assert {"next_action", "request"}.issubset(names)
    result = conductor.ConductResult(status="complete", state={}, summary="done")
    assert result.next_action is None
    assert result.request is None


def test_phase3_ci_parity_api_surface_is_declared():
    option_fields = {field.name for field in fields(conductor.ConductOptions)}
    assert {
        "run_ci_parity",
        "ci_cmd",
        "skip_ci_parity",
        "ci_parity_spawn",
    } <= option_fields

    request_fields = {field.name for field in fields(conductor.CIParitySpawnRequest)}
    assert {
        "plan_path",
        "base_sha",
        "head_sha",
        "ci_entrypoint_kind",
        "ci_cmd",
        "repo_root",
        "plan_id",
        "request_written_at_unix",
    } <= request_fields


def test_step_8_impl_commit_has_conducted_by_trailer(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (
            _stage(r, "src/a.py", "x = 1\n"),
            _impl_report(0, ["src/a.py"]),
        )[1],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    runner = StubTestRunner(queue=[_passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )

    assert result.status == "awaiting_user"
    body = _git(["show", "-s", "--format=%B", "HEAD"], repo).stdout
    assert "Conducted-By: codex" in body
    assert f"plan: {plan}" in body
    assert "phase: 1" in body


def test_plan_id_helpers_are_distinguishable_by_name_and_doc(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    opts = ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")

    state_path = _state_path(opts)
    handoff_id = conductor._compute_cross_runtime_plan_id(plan)

    assert _state_path.__name__ == "_state_path"
    assert (
        conductor._compute_cross_runtime_plan_id.__name__
        == "_compute_cross_runtime_plan_id"
    )
    assert "state-codex-" in state_path.name
    assert handoff_id not in state_path.name


def test_stall_blocks_at_threshold(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    opts = _phase1_opts(
        repo, plan, max_iterations=10, max_iterations_ceiling=10, stall_threshold=2
    )

    assert _check_iteration_bound(state, opts, "same") is None
    assert _check_iteration_bound(state, opts, "same") is None
    result = _check_iteration_bound(state, opts, "same")

    assert result is not None
    assert result.status == "blocked"
    assert state["iteration_count"] == 3
    assert state["stall_count"] == 2
    assert state["blocker"] == "stall_threshold exceeded"


def test_progress_resets_counter(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    opts = _phase1_opts(
        repo, plan, max_iterations=10, max_iterations_ceiling=10, stall_threshold=2
    )

    assert _check_iteration_bound(state, opts, "same") is None
    assert _check_iteration_bound(state, opts, "same") is None
    assert state["stall_count"] == 1

    assert _check_iteration_bound(state, opts, "new") is None
    assert state["stall_count"] == 0

    assert _check_iteration_bound(state, opts, "new") is None
    assert state["stall_count"] == 1


def test_hard_ceiling_blocks_at_9(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    opts = _phase1_opts(
        repo, plan, max_iterations=99, max_iterations_ceiling=8, stall_threshold=99
    )

    for i in range(8):
        assert _check_iteration_bound(state, opts, f"sig-{i}") is None
    result = _check_iteration_bound(state, opts, "sig-8")

    assert result is not None
    assert result.status == "blocked"
    assert state["iteration_count"] == 9
    assert state["blocker"] == "max_iterations_ceiling exceeded"


def test_legacy_max_iterations_default_3_stalled(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    opts = _phase1_opts(
        repo,
        plan,
        max_iterations=3,
        max_iterations_ceiling=8,
        stall_threshold=99,
    )

    for _ in range(3):
        assert _check_iteration_bound(state, opts, "same") is None
    result = _check_iteration_bound(state, opts, "same")

    assert result is not None
    assert state["iteration_count"] == 4
    assert state["blocker"] == "max_iterations exceeded (legacy)"


def test_legacy_max_iterations_default_3_progressing_also_blocks(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    opts = _phase1_opts(
        repo,
        plan,
        max_iterations=3,
        max_iterations_ceiling=8,
        stall_threshold=2,
    )

    for i in range(3):
        assert _check_iteration_bound(state, opts, f"sig-{i}") is None
    result = _check_iteration_bound(state, opts, "sig-3")

    assert result is not None
    assert state["iteration_count"] == 4
    assert state["stall_count"] == 0
    assert state["blocker"] == "max_iterations exceeded (legacy)"


def test_stall_signatures_truncate_to_length_2_across_many_iterations(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    opts = _phase1_opts(
        repo, plan, max_iterations=99, max_iterations_ceiling=99, stall_threshold=99
    )

    for i in range(6):
        assert _check_iteration_bound(state, opts, f"sig-{i}") is None
        assert len(state["stall_signatures"]) <= 2
        assert state["stall_signatures"] == [
            f"sig-{j}" for j in range(max(0, i - 1), i + 1)
        ]


def test_helper_is_single_increment_source_three_sites(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    opts = _phase1_opts(
        repo, plan, max_iterations=99, max_iterations_ceiling=99, stall_threshold=99
    )

    for call_site in [
        "_run_phase test-failure branch",
        "_run_phase hook-failure branch",
        "_retry_after_hook_failure hook retry",
    ]:
        state = _bound_state()
        before = state["iteration_count"]
        assert _check_iteration_bound(state, opts, call_site) is None
        assert state["iteration_count"] == before + 1
        # Pre-Phase-1 audit: each old call site incremented once immediately
        # before deciding whether to continue or block. Centralising the helper
        # must preserve that observable count at the equivalent return point.
        assert state["iteration_count"] == 1


def test_precommit_hook_stall_fires_bound(repo, monkeypatch: pytest.MonkeyPatch):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    hooks_dir = repo / ".git" / "hooks"
    hook = hooks_dir / "pre-commit"
    hook.write_text(
        "#!/bin/sh\necho 'ruff................................................................Failed' >&2\nexit 1\n"
    )
    hook.chmod(0o755)

    progress = __import__("conduct.progress", fromlist=["iteration_signature"])
    seen_signatures: list[str] = []
    original_signature = progress.iteration_signature

    def record_signature(failing_tests: list[str], staged_diff_stat: str) -> str:
        seen_signatures.append(original_signature(failing_tests, staged_diff_stat))
        assert failing_tests == ["ruff"]
        return seen_signatures[-1]

    monkeypatch.setattr(progress, "iteration_signature", record_signature)
    monkeypatch.setattr(
        conductor, "iteration_signature", record_signature, raising=False
    )

    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script(
        "implementer",
        1,
        lambda req, r: (_stage(r, "src/a.py", "x=2\n"), _impl_report(1, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing(), _passing()]),
            max_iterations=10,
            max_iterations_ceiling=10,
            stall_threshold=1,
        )
    )

    assert result.status == "blocked"
    assert result.state["iteration_count"] == 2
    assert result.state["blocker"] == "stall_threshold exceeded"
    assert len(seen_signatures) == 2


def test_precommit_hook_garbled_output_uses_empty_failing_tests(
    repo, monkeypatch: pytest.MonkeyPatch
):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    hook = repo / ".git" / "hooks" / "pre-commit"
    hook.write_text("#!/bin/sh\necho '@@@ not hook id output @@@' >&2\nexit 1\n")
    hook.chmod(0o755)

    progress = __import__("conduct.progress", fromlist=["iteration_signature"])
    seen_signatures: list[str] = []

    def assert_empty_tests(failing_tests: list[str], staged_diff_stat: str) -> str:
        assert failing_tests == []
        assert staged_diff_stat
        seen_signatures.append("diff-only")
        return "diff-only"

    monkeypatch.setattr(progress, "iteration_signature", assert_empty_tests)
    monkeypatch.setattr(
        conductor, "iteration_signature", assert_empty_tests, raising=False
    )

    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (_stage(r, "src/a.py", "x=1\n"), _impl_report(0, ["src/a.py"]))[
            1
        ],
    )
    spawner.script("implementer", 1, lambda req, r: _impl_report(1, ["src/a.py"]))
    spawner.script("test-writer", 0, lambda req, r: _test_report())

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing(), _passing()]),
            max_iterations=1,
            max_iterations_ceiling=10,
            stall_threshold=10,
        )
    )

    assert result.status == "awaiting_user"
    assert seen_signatures == ["diff-only"]


def test_pre_phase_1_state_files_load_cleanly_under_new_loader(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    state.pop("schema_version")
    state.pop("stall_signatures")
    state.pop("stall_count")
    state["plan_path"] = str(plan)
    state["plan_content_hash"] = compute_plan_hash(plan)

    migrated = conductor._normalize_loaded_state(conductor._migrate_loaded_state(state))

    assert migrated["schema_version"] == conductor.STATE_SCHEMA_VERSION
    assert migrated["stall_signatures"] == []
    assert migrated["stall_count"] == 0
    assert migrated["state_author"] == "codex"


@pytest.mark.parametrize("marker", [True, 2])
def test_incompatible_with_pre_vn_loader_hard_fails(marker):
    state = _bound_state() | {"schema_version": 99, "incompatible_with_pre_vN": marker}

    with pytest.raises(RuntimeError, match="requires a newer conduct loader"):
        conductor._normalize_loaded_state(conductor._migrate_loaded_state(state))


@pytest.mark.parametrize("marker", [False, 0, None])
def test_false_or_zero_incompatible_marker_passes(marker):
    state = _bound_state() | {"schema_version": 2, "incompatible_with_pre_vN": marker}

    migrated = conductor._normalize_loaded_state(conductor._migrate_loaded_state(state))

    assert migrated["schema_version"] == conductor.STATE_SCHEMA_VERSION


def test_unknown_schema_version_99_loader_warns_once(
    capsys: pytest.CaptureFixture[str],
):
    state = _bound_state() | {"schema_version": 99}
    monkeypatch_msg = "_UNKNOWN_SCHEMA_VERSION_WARNED"
    setattr(conductor, monkeypatch_msg, False)

    loaded = conductor._normalize_loaded_state(conductor._migrate_loaded_state(state))

    assert loaded["schema_version"] == conductor.STATE_SCHEMA_VERSION
    assert (
        capsys.readouterr().err.count(
            "state file written by newer schema_version=99; reading known fields only"
        )
        == 1
    )


def test_unknown_schema_version_warning_suppressed_on_second_load_same_process(
    capsys: pytest.CaptureFixture[str],
):
    state = _bound_state() | {"schema_version": 99}
    conductor._UNKNOWN_SCHEMA_VERSION_WARNED = False

    conductor._normalize_loaded_state(conductor._migrate_loaded_state(dict(state)))
    conductor._normalize_loaded_state(conductor._migrate_loaded_state(dict(state)))

    assert (
        capsys.readouterr().err.count(
            "state file written by newer schema_version=99; reading known fields only"
        )
        == 1
    )


def test_unknown_schema_version_warning_refires_after_resume(tmp_path: Path):
    state_path = tmp_path / "state.json"
    state_path.write_text(json.dumps(_bound_state() | {"schema_version": 99}))
    skills_dir = Path(__file__).resolve().parents[2]
    script = textwrap.dedent(
        f"""\
        import json
        from pathlib import Path
        import sys
        sys.path.insert(0, {str(skills_dir)!r})
        import conduct.conductor as conductor
        state = json.loads(Path({str(state_path)!r}).read_text())
        conductor._normalize_loaded_state(conductor._migrate_loaded_state(state))
        """
    )

    first = subprocess.run(
        ["python", "-c", script], capture_output=True, text=True, check=True
    )
    second = subprocess.run(
        ["python", "-c", script], capture_output=True, text=True, check=True
    )

    expected = (
        "state file written by newer schema_version=99; reading known fields only"
    )
    assert expected in first.stderr
    assert expected in second.stderr


def test_codex_phase_1_loader_roundtrips_unknown_phase_3_fields(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_path = _state_file(repo, plan)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    phase3_state = _bound_state() | {
        "schema_version": 99,
        "plan_path": str(plan),
        "plan_content_hash": compute_plan_hash(plan),
        "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
        "ci_parity_dispatched": True,
        "ci_parity_missing_resume_count": 2,
    }
    state_path.write_text(json.dumps(phase3_state))
    opts = _phase1_opts(repo, plan, resume=True)

    loaded, existed = conductor._load_or_init_state(opts, compute_plan_hash(plan))
    assert existed is True
    conductor._persist_state(opts, loaded)
    reloaded = json.loads(state_path.read_text())

    assert reloaded["ci_parity_dispatched"] is True
    assert reloaded["ci_parity_missing_resume_count"] == 2


def test_cross_runtime_schema_divergence_phases_1_2_both_load_each_other(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    base = _bound_state() | {
        "plan_path": str(plan),
        "plan_content_hash": compute_plan_hash(plan),
        "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
        "stall_signatures": ["a"],
        "stall_count": 1,
        "autonomous": False,
        "plan_id": "abc123def456",
    }

    for state_author, schema_version in [("claude", 1), ("codex", 2)]:
        loaded = conductor._normalize_loaded_state(
            conductor._migrate_loaded_state(
                base | {"state_author": state_author, "schema_version": schema_version}
            )
        )
        assert loaded["state_author"] == state_author
        assert loaded["stall_signatures"] == ["a"]
        assert loaded["stall_count"] == 1


def test_state_path_includes_runtime_author(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)

    state_path = _state_file(repo, plan)

    assert state_path.name.startswith("state-codex-")
    assert state_path.suffix == ".json"
    assert state_path.with_suffix(state_path.suffix + ".lock").name.startswith(
        "state-codex-"
    )


def test_legacy_shared_state_does_not_skip_other_runtime(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    legacy = _legacy_shared_state_file(repo, plan)
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_text(
        json.dumps(
            _bound_state()
            | {
                "plan_path": str(plan),
                "plan_content_hash": compute_plan_hash(plan),
                "base_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
                "current_phase_title": "Add a file",
                "completed_phases": [
                    {
                        "index": 0,
                        "label": "1",
                        "title": "Add a file",
                        "commit_sha": _git(["rev-parse", "HEAD"], repo).stdout.strip(),
                        "tests": "passed",
                        "iterations": 0,
                    }
                ],
                "phase_index": 1,
                "state_author": "claude",
            }
        )
    )
    spawner = StubSpawner(repo)
    spawner.script(
        "implementer",
        0,
        lambda req, r: (
            _stage(r, "src/a.py", "x = 1\n"),
            _impl_report(0, ["src/a.py"]),
        )[1],
    )
    spawner.script("test-writer", 0, lambda req, r: _test_report())

    result = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=spawner,
            test_runner=StubTestRunner(queue=[_passing()]),
        )
    )

    assert result.status == "awaiting_user"
    assert [call.role for call in spawner.calls] == ["implementer", "test-writer"]
    assert legacy.exists()
    assert _state_file(repo, plan).exists()


def test_runtime_specific_locks_do_not_collide(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    codex_state = _state_file(repo, plan)
    claude_state = (
        repo / ".conduct" / codex_state.name.replace("state-codex-", "state-claude-", 1)
    )

    assert codex_state != claude_state
    with (
        StateLock(codex_state.with_suffix(codex_state.suffix + ".lock")),
        StateLock(claude_state.with_suffix(claude_state.suffix + ".lock")),
    ):
        pass


def test_stall_threshold_greater_than_max_iterations_warns(
    repo, capsys: pytest.CaptureFixture[str]
):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)

    opts = ConductOptions(
        plan_path=plan,
        repo_root=repo,
        spawn=StubSpawner(repo),
        test_runner=StubTestRunner(),
        max_iterations=3,
        max_iterations_ceiling=8,
        stall_threshold=5,
    )
    conductor._validate_options(opts)

    assert "stall_threshold=5 is >= max_iterations=3" in capsys.readouterr().err


def test_stall_threshold_greater_than_max_iterations_legacy_dominates(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state = _bound_state()
    opts = _phase1_opts(
        repo, plan, max_iterations=3, max_iterations_ceiling=8, stall_threshold=5
    )

    for _ in range(3):
        assert _check_iteration_bound(state, opts, "same") is None
    result = _check_iteration_bound(state, opts, "same")

    assert result is not None
    assert state["iteration_count"] == 4
    assert state["blocker"] == "max_iterations exceeded (legacy)"


def test_legacy_no_flags_handback_per_phase(repo, lock_counter):
    plan = _scratch_plan(repo, PLAN_TWO_PHASES)

    def make_spawner():
        spawner = StubSpawner(repo)
        spawner.script(
            "implementer",
            0,
            lambda req, r: (
                _stage(r, f"src/{'a' if req.phase_label == '1' else 'b'}.py", "v=1\n"),
                _impl_report(0, [f"src/{'a' if req.phase_label == '1' else 'b'}.py"]),
            )[1],
        )
        spawner.script("test-writer", 0, lambda req, r: _test_report())
        return spawner

    first = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=make_spawner(),
            test_runner=StubTestRunner(queue=[_passing()]),
        )
    )
    assert first.status == "awaiting_user"
    assert len(first.state["completed_phases"]) == 1
    assert first.summary.startswith("Phase 1: First\n")
    assert "  Spawn: " in first.summary
    assert "  Tests: passed\n" in first.summary
    assert "  Iterations: 0\n" in first.summary
    assert first.next_command == f"Run: /conduct --resume {plan}"
    assert lock_counter.count == 1

    second = conduct(
        ConductOptions(
            plan_path=plan,
            repo_root=repo,
            spawn=make_spawner(),
            test_runner=StubTestRunner(queue=[_passing()]),
            resume=True,
        )
    )
    assert second.status == "awaiting_user"
    assert len(second.state["completed_phases"]) == 2
    assert second.summary.startswith("Phase 2: Second\n")
    assert lock_counter.count == 2
