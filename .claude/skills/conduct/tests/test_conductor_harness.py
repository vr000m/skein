"""Stub-spawner harness tests for the conductor algorithm.

Covers Phase 6 scenarios that depend on subagent branching but don't require
spawning real Agent-tool subagents:

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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import pytest

from conductor import (
    ConductOptions,
    SpawnRequest,
    _repo_default_test_cmd,
    _state_path,
    abort_run,
    conduct,
    default_lint_check,
    detect_lint_command,
    pause_phase,
)
from marker import write_marker
from runner import (
    TestResult as _TestResult,
)  # rename — pytest tries to collect any class named Test*


def _state_file_for(plan: Path, repo: Path) -> Path:
    return _state_path(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )


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
    state = json.loads(_state_file_for(plan, repo).read_text())
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
        )
    )
    assert result.status == "blocked"
    assert "stalled" in result.state["blocker"]
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


def test_precommit_hook_failure_routes_to_fix_loop(repo):
    """Install a hook that fails the first commit attempt and passes the second.

    The conductor must treat the first failure as a fix-loop iteration (not a
    hard error), respawn the implementer with the hook output as test_failures,
    and complete the phase on the next attempt.
    """
    hooks_dir = repo / ".git" / "hooks"
    counter = repo / ".git" / "hook-counter"
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


def test_pause_phase_stashes_and_marks_state(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    # Pre-create state so pause has something to mark.
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file_for(plan, repo)
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
    stash = _git(["stash", "list"], repo).stdout
    assert "conduct-pause-phase" in stash


def test_abort_run_deletes_state_without_touching_tree(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    state_file = _state_file_for(plan, repo)
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
    _state_file_for(plan, repo).write_text(
        json.dumps(
            {
                "plan_path": str(plan),
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


# ---------------------------------------------------------------------------
# C3: default_lint_check probe (SKILL.md Preflight Step 3)
# ---------------------------------------------------------------------------


def _which_stub(present: set[str]):
    """Returns a shutil.which replacement that reports only ``present``.

    ``git`` is always resolvable because preflight hard-stops without it and
    these lint-detection tests want to exercise the lint-check branch, not
    the git-missing branch.
    """
    present_with_git = present | {"git"}
    return lambda name: f"/usr/bin/{name}" if name in present_with_git else None


def test_detect_lint_command_returns_none_when_nothing_available(tmp_path, monkeypatch):
    monkeypatch.setattr("conductor.shutil.which", _which_stub(set()))
    assert detect_lint_command(tmp_path) is None


def test_detect_lint_command_prefers_pre_commit(tmp_path, monkeypatch):
    (tmp_path / ".pre-commit-config.yaml").write_text("repos: []\n")
    (tmp_path / "Makefile").write_text("lint:\n\tpython -m flake8\n")
    (tmp_path / "package.json").write_text('{"scripts": {"lint": "eslint ."}}\n')
    monkeypatch.setattr(
        "conductor.shutil.which", _which_stub({"pre-commit", "make", "npm", "ruff"})
    )
    assert detect_lint_command(tmp_path) == ["pre-commit", "run", "--all-files"]


def test_detect_lint_command_skips_pre_commit_when_binary_missing(
    tmp_path, monkeypatch
):
    (tmp_path / ".pre-commit-config.yaml").write_text("repos: []\n")
    (tmp_path / "Makefile").write_text("lint:\n\tflake8\n")
    monkeypatch.setattr("conductor.shutil.which", _which_stub({"make"}))
    assert detect_lint_command(tmp_path) == ["make", "lint"]


def test_detect_lint_command_falls_through_to_npm_run_lint(tmp_path, monkeypatch):
    (tmp_path / "package.json").write_text('{"scripts": {"lint": "eslint ."}}\n')
    monkeypatch.setattr("conductor.shutil.which", _which_stub({"npm"}))
    assert detect_lint_command(tmp_path) == ["npm", "run", "lint"]


def test_detect_lint_command_falls_through_to_ruff_for_python_repo(
    tmp_path, monkeypatch
):
    (tmp_path / "pyproject.toml").write_text("[project]\nname='x'\n")
    monkeypatch.setattr("conductor.shutil.which", _which_stub({"ruff"}))
    assert detect_lint_command(tmp_path) == ["ruff", "check", "."]


def test_detect_lint_command_skips_ruff_when_no_python_signal(tmp_path, monkeypatch):
    monkeypatch.setattr("conductor.shutil.which", _which_stub({"ruff"}))
    assert detect_lint_command(tmp_path) is None


def test_default_lint_check_returns_none_when_no_tool_available(tmp_path, monkeypatch):
    monkeypatch.setattr("conductor.shutil.which", _which_stub(set()))
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
    monkeypatch.setattr("conductor.shutil.which", _which_stub({"make"}))
    diag = default_lint_check(tmp_path)
    assert diag is not None
    assert "make lint" in diag
    assert "fake lint failure" in diag


def test_default_lint_check_returns_none_on_passing_check(tmp_path, monkeypatch):
    if shutil.which("make") is None:
        pytest.skip("make not available")
    (tmp_path / "Makefile").write_text("lint:\n\t@true\n")
    monkeypatch.setattr("conductor.shutil.which", _which_stub({"make"}))
    assert default_lint_check(tmp_path) is None


def test_run_preflight_invokes_default_lint_check_when_no_override(repo, monkeypatch):
    """End-to-end: preflight without a stub uses default_lint_check, which
    detects the seeded Makefile lint failure and hard-stops before any spawn.
    """
    if shutil.which("make") is None:
        pytest.skip("make not available")
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    (repo / "Makefile").write_text(
        "lint:\n\t@echo 'preflight diagnostic seeded'; exit 1\n"
    )
    monkeypatch.setattr("conductor.shutil.which", _which_stub({"make"}))
    spawner = StubSpawner(repo)
    runner = StubTestRunner()

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "preflight_fail"
    assert "preflight diagnostic seeded" in result.diagnostic
    assert spawner.calls == []


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


def test_state_file_written_by_conduct_matches_documented_schema(repo):
    """Round-trip through conduct() and assert the on-disk state has the
    documented keys. Guards against drift between SKILL.md's schema block,
    STATE_REQUIRED_KEYS, and what conductor.py actually persists.
    """
    from tests.test_state import STATE_REQUIRED_KEYS  # type: ignore

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
    state_path = _state_file_for(plan, repo)
    on_disk = json.loads(state_path.read_text())
    missing = STATE_REQUIRED_KEYS - on_disk.keys()
    assert not missing, f"conductor-written state missing keys: {missing}"
    assert on_disk["last_summary"], "last_summary should be populated on handback"
    assert len(on_disk["plan_content_hash"]) == 40


def test_nested_precommit_hook_failure_inside_retry_loop_recovers(repo):
    """Chain two hook failures: first commit fails, retry loop attempts a
    second commit, hook fails again, third attempt succeeds. Exercises the
    inner ``except _CommitHookFailure`` in ``_retry_after_hook_failure`` —
    the code path that handles a hook-fail inside a hook-retry iteration.
    """
    hooks_dir = repo / ".git" / "hooks"
    counter = repo / ".git" / "hook-counter"
    counter.write_text("0\n")
    hook = hooks_dir / "pre-commit"
    hook.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            n=$(cat {counter})
            echo $((n+1)) > {counter}
            if [ "$n" = "0" ] || [ "$n" = "1" ]; then
              echo "hook failure $n" >&2
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
    spawner.script("implementer", 2, attempt)
    spawner.script("test-writer", 0, lambda req, r: _test_report())
    # Three _passing() results so every test invocation (initial + two retries)
    # returns success and the failure mode under test is the hook, not tests.
    runner = StubTestRunner(queue=[_passing(), _passing(), _passing()])

    result = conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )
    assert result.status == "awaiting_user", result
    # Two hook failures consumed two fix-loop iterations.
    assert result.state["iteration_count"] == 2
    log = _git(["log", "--oneline"], repo).stdout
    assert "phase 1" in log
    impl_calls = [c for c in spawner.calls if c.role == "implementer"]
    # Every hook failure should have been surfaced to a respawned implementer.
    hook_failures_seen = [c for c in impl_calls if "hook failure" in c.test_failures]
    assert len(hook_failures_seen) >= 2


def test_state_path_disambiguates_same_basename_plans(repo):
    """Two plans sharing a basename at different paths must not collide."""
    plans_a = repo / "docs" / "dev_plans"
    plans_a.mkdir(parents=True)
    plan_a = plans_a / "shared.md"
    plan_a.write_text("# A\n")

    plans_b = repo / "archive"
    plans_b.mkdir()
    plan_b = plans_b / "shared.md"
    plan_b.write_text("# B\n")

    sp_a = _state_file_for(plan_a, repo)
    sp_b = _state_file_for(plan_b, repo)
    assert sp_a != sp_b
    assert sp_a.parent == sp_b.parent
    assert sp_a.name.startswith("state-shared-") and sp_a.suffix == ".json"
    assert sp_b.name.startswith("state-shared-") and sp_b.suffix == ".json"


def test_legacy_state_file_migrates_on_load(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    legacy = state_dir / f"state-{plan.stem}.json"
    legacy_payload = {
        "plan_path": str(plan),
        "plan_content_hash": "a" * 40,
        "base_sha": "b" * 40,
        "phase_index": 0,
        "completed_phases": [],
        "last_summary": "",
        "iteration_count": 0,
        "status": "running",
        "blocker": None,
    }
    legacy.write_text(json.dumps(legacy_payload))

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

    conduct(
        ConductOptions(
            plan_path=plan, repo_root=repo, spawn=spawner, test_runner=runner
        )
    )

    new_path = _state_file_for(plan, repo)
    assert new_path.exists()
    assert not legacy.exists()


def test_legacy_state_file_not_migrated_when_plan_path_differs(repo):
    """A same-basename neighbour's legacy state must not be hijacked."""
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    legacy = state_dir / f"state-{plan.stem}.json"
    # Recorded plan_path points at a different file with the same basename.
    other = repo / "archive" / f"{plan.stem}.md"
    other.parent.mkdir(parents=True)
    other.write_text("# other\n")
    legacy.write_text(json.dumps({"plan_path": str(other)}))

    from conductor import _migrate_legacy_state_file

    _migrate_legacy_state_file(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert legacy.exists()
    assert not _state_file_for(plan, repo).exists()


def test_legacy_state_file_migrates_optimistically_when_plan_path_missing(repo):
    """If the legacy file lacks a plan_path field, migrate optimistically."""
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    legacy = state_dir / f"state-{plan.stem}.json"
    legacy.write_text(json.dumps({"phase_index": 0, "iteration_count": 0}))

    from conductor import _migrate_legacy_state_file

    _migrate_legacy_state_file(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert not legacy.exists()
    assert _state_file_for(plan, repo).exists()


def test_conduct_refuses_symlinked_state_path(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    victim = repo / "victim.txt"
    victim.write_text("keep me\n")
    sp = _state_file_for(plan, repo)
    sp.symlink_to(victim)

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


def test_abort_run_refuses_symlinked_state_path(repo):
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    victim = repo / "victim.txt"
    victim.write_text("keep me\n")
    sp = _state_file_for(plan, repo)
    sp.symlink_to(victim)

    result = abort_run(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert result.status == "blocked"
    assert victim.read_text() == "keep me\n"
    assert sp.is_symlink()


def test_legacy_state_migration_skipped_when_legacy_is_symlink(repo):
    """A symlinked legacy state file must not be followed during migration."""
    plan = _scratch_plan(repo, PLAN_ONE_PHASE)
    state_dir = repo / ".conduct"
    state_dir.mkdir()
    victim = repo / "victim.json"
    victim.write_text(json.dumps({"plan_path": str(plan)}))
    legacy = state_dir / f"state-{plan.stem}.json"
    legacy.symlink_to(victim)

    from conductor import _migrate_legacy_state_file

    _migrate_legacy_state_file(
        ConductOptions(plan_path=plan, repo_root=repo, spawn=lambda r: "")
    )
    assert legacy.is_symlink()
    assert victim.exists()
    assert not _state_file_for(plan, repo).exists()


def test_resume_after_above_marker_edit_refreshes_marker_and_resyncs_state_hash(
    repo, capsys
):
    """End-to-end: complete phase 1 → edit the contract section above the marker
    (simulating a phase that legitimately amended the plan) → /conduct --resume
    should auto-refresh the marker AND resync state.plan_content_hash to the
    new value rather than leaving it pointing at the pre-edit hash.
    """
    from marker import compute_plan_hash

    plan = _scratch_plan(repo, PLAN_TWO_PHASES)
    spawner = StubSpawner(repo)
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
    pre_state = json.loads(_state_file_for(plan, repo).read_text())
    pre_hash = pre_state["plan_content_hash"]

    # Phase 2 amends the contract section above the marker. The marker hash is
    # now stale; the workspace below the marker is untouched.
    text = plan.read_text()
    assert "Phase 2: Second" in text
    plan.write_text(text.replace("Phase 2: Second", "Phase 2: Second (refined)"))
    new_plan_hash = compute_plan_hash(plan)
    assert new_plan_hash != pre_hash  # sanity

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
    # Marker line itself was rewritten; state's recorded hash matches it.
    post_state = json.loads(_state_file_for(plan, repo).read_text())
    assert post_state["plan_content_hash"] == compute_plan_hash(plan)
    assert post_state["plan_content_hash"] != pre_hash
    # Stderr trail confirms preflight took the auto-refresh path, not the
    # hard-stop path.
    assert "auto-refreshed on resume" in capsys.readouterr().err
