"""In-process conductor implementation of the SKILL.md per-phase algorithm.

This module exists primarily as a deterministic test harness. Real /conduct
runs are driven by main Claude inlining the SKILL.md algorithm with the Agent
tool as the spawn primitive — but that path is impossible to unit-test because
``Agent`` calls cost real budget and produce non-deterministic output.

Here we factor the loop into a function with three injectable seams:

- ``spawn_fn(SpawnRequest) -> str`` — replaces the ``Agent`` tool. Receives a
  request describing what role to spawn and the rendered prompt context;
  returns the raw text the subagent would have printed (must end in a fenced
  ```json block per the schema in implementer-prompt.md / test-writer-prompt.md).
- ``test_runner_fn(cmd, timeout) -> TestResult`` — defaults to ``runner.run_tests``;
  tests can inject scripted results without spawning subprocesses.
- ``lint_check_fn() -> Optional[str]`` — defaults to no-op; tests inject a stub
  that returns a diagnostic string when a pre-existing lint failure is seeded.

The module is intentionally NOT a CLI. SKILL.md is the user-facing contract;
this is the algorithmic core that a human-readable algorithm description and a
LLM-driven harness both target.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from lock import StateLock
from marker import compute_plan_hash, marker_is_stale, read_marker
from parser import Phase, files_overlap, parse_phases
from runner import TestResult, run_tests
from schema import SchemaError, parse_report


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------


@dataclass
class SpawnRequest:
    """Everything the spawn seam needs to produce a subagent reply.

    Mirrors the placeholders enumerated in the prompt templates, plus a couple
    of fields a stub harness needs for scripted dispatch (role, iteration).
    """

    role: str  # 'implementer' | 'test-writer' | 'reviewer'
    plan_path: str
    phase_position: int
    phase_label: str
    phase_title: str
    iteration: int
    base_sha: str
    prior_diff: str = ""
    test_failures: str = ""
    diff: str = ""  # reviewer only


SpawnFn = Callable[[SpawnRequest], str]
TestRunnerFn = Callable[[str, float], TestResult]
LintCheckFn = Callable[[], Optional[str]]
HandbackFn = Callable[[dict], None]


@dataclass
class ConductOptions:
    plan_path: Path
    repo_root: Path
    spawn: SpawnFn
    test_runner: TestRunnerFn = run_tests
    # If None, run_preflight runs ``default_lint_check(repo_root)`` — which
    # probes for pre-commit / make lint / npm run lint / ruff per SKILL.md
    # Step 3. Tests inject a stub to bypass real subprocess work.
    lint_check: Optional[LintCheckFn] = None
    test_cmd_override: Optional[str] = None
    test_timeout: float = 300.0
    max_iterations: int = 3
    resume: bool = False
    on_handback: Optional[HandbackFn] = None


@dataclass
class ConductResult:
    status: str  # 'awaiting_user' | 'blocked' | 'schema_error' | 'complete' | 'preflight_fail'
    state: dict
    summary: str
    next_command: Optional[str] = None
    diagnostic: Optional[str] = None


# ---------------------------------------------------------------------------
# Git helpers (cwd-scoped)
# ---------------------------------------------------------------------------


def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=check,
    )


def _head_sha(repo_root: Path) -> str:
    return _git(["rev-parse", "HEAD"], repo_root).stdout.strip()


def _staged_diff(repo_root: Path) -> str:
    return _git(["diff", "--cached"], repo_root).stdout


def _reset_index(repo_root: Path) -> None:
    _git(["reset"], repo_root)


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------


def run_preflight(opts: ConductOptions) -> Optional[ConductResult]:
    """Returns None on success, else a ConductResult describing the hard stop."""
    if not opts.plan_path.exists():
        return ConductResult(
            status="preflight_fail",
            state={},
            summary=f"plan not found: {opts.plan_path}",
            diagnostic=f"plan not found: {opts.plan_path}",
        )

    # Marker hashing shells out to ``git hash-object``; state init does the
    # same. Fail fast here rather than with a FileNotFoundError deep in the
    # stack when ``git`` is missing from PATH.
    if shutil.which("git") is None:
        return ConductResult(
            status="preflight_fail",
            state={},
            summary="git not found on PATH",
            diagnostic="`git` is required for marker hashing and commit; install git and retry.",
        )

    marker = read_marker(opts.plan_path)
    if marker is None:
        return ConductResult(
            status="preflight_fail",
            state={},
            summary="no review marker",
            diagnostic=f"Run: /review-plan {opts.plan_path}",
        )
    stale = marker_is_stale(opts.plan_path)
    if stale is True:
        return ConductResult(
            status="preflight_fail",
            state={},
            summary="stale review marker",
            diagnostic=f"Run: /review-plan {opts.plan_path}",
        )

    lint_check = opts.lint_check or (lambda: default_lint_check(opts.repo_root))
    lint_diag = lint_check()
    if lint_diag:
        return ConductResult(
            status="preflight_fail",
            state={},
            summary="pre-existing lint failure",
            diagnostic=(
                "Tree has pre-existing lint/hook failures; fix them before running this skill\n"
                + lint_diag
            ),
        )
    return None


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


class UnsafeConductPathError(RuntimeError):
    pass


# Cap on legacy state-file size during migration. Bounds attacker-supplied
# JSON: a planted multi-GB file in `.conduct/` would otherwise OOM the load.
_MAX_LEGACY_STATE_BYTES = 1 * 1024 * 1024  # 1 MiB


def _ensure_safe_conduct_dir(repo_root: Path) -> Path:
    """Mirror of Codex `_ensure_safe_conduct_dir`: refuse `.conduct/` when it
    is a symlink or non-directory. Ports the path-safety helper that PR-cb05a15
    added on the Codex side."""
    conduct_dir = repo_root / ".conduct"
    if conduct_dir.exists():
        if conduct_dir.is_symlink() or not conduct_dir.is_dir():
            raise UnsafeConductPathError(f"unsafe conduct dir: {conduct_dir}")
        return conduct_dir
    conduct_dir.mkdir(parents=True, exist_ok=True)
    if conduct_dir.is_symlink() or not conduct_dir.is_dir():
        raise UnsafeConductPathError(f"unsafe conduct dir: {conduct_dir}")
    return conduct_dir


def _ensure_safe_fs_path(path: Path, *, expect_dir: Optional[bool] = None) -> None:
    try:
        path.lstat()
    except FileNotFoundError:
        return
    if path.is_symlink():
        raise UnsafeConductPathError(f"unsafe conduct path: {path}")
    if expect_dir is True and not path.is_dir():
        raise UnsafeConductPathError(f"expected directory at conduct path: {path}")
    if expect_dir is False and path.is_dir():
        raise UnsafeConductPathError(f"expected file at conduct path: {path}")


def _safe_write_text(path: Path, text: str) -> None:
    _ensure_safe_fs_path(path, expect_dir=False)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(str(path), flags, 0o644)
    try:
        os.write(fd, text.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def _safe_read_legacy_state(path: Path) -> Optional[bytes]:
    """Open the legacy state file refusing to follow symlinks, capped at
    `_MAX_LEGACY_STATE_BYTES`. Returns None if the file is missing, a symlink,
    or exceeds the cap — all of which mean migration must abort silently."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(path), flags)
    except (FileNotFoundError, OSError):
        return None
    try:
        st = os.fstat(fd)
        if st.st_size > _MAX_LEGACY_STATE_BYTES:
            return None
        return os.read(fd, _MAX_LEGACY_STATE_BYTES)
    finally:
        os.close(fd)


# `_state_path` is intentionally module-private but is also imported by tests
# in both the Claude and Codex mirrors as a stable test seam. Treat it as a
# semi-public path helper: rename only with a coordinated test update.
def _state_path(opts: ConductOptions) -> Path:
    try:
        rel_plan = (
            opts.plan_path.resolve().relative_to(opts.repo_root.resolve()).as_posix()
        )
    except ValueError:
        rel_plan = opts.plan_path.resolve().as_posix()
    digest = hashlib.sha1(rel_plan.encode("utf-8")).hexdigest()[:12]
    return opts.repo_root / ".conduct" / f"state-{opts.plan_path.stem}-{digest}.json"


def _legacy_state_path(opts: ConductOptions) -> Path:
    return opts.repo_root / ".conduct" / f"state-{opts.plan_path.stem}.json"


def _migrate_legacy_state_file(opts: ConductOptions) -> None:
    """Rename a pre-digest state file to the digest-suffixed path.

    Migration is path-driven (file rename), distinct from Codex's
    `_migrate_loaded_state` which is content-driven (schema-version migration
    on already-loaded JSON). If both helpers ever live in the same conductor,
    path migration MUST run first so the schema migration sees the new path.

    Only migrates when the legacy file's recorded `plan_path` matches the
    current plan; missing `plan_path` is treated as ambiguous and migrated
    optimistically (the file is still in `.conduct/state-<basename>.json`,
    which by construction is unique per basename in this directory).
    """
    sp = _state_path(opts)
    legacy = _legacy_state_path(opts)
    if sp.exists() or not legacy.exists() or legacy.is_symlink():
        return

    raw = _safe_read_legacy_state(legacy)
    if raw is None:
        return
    try:
        recorded = json.loads(raw.decode("utf-8", errors="strict")).get("plan_path")
    except (UnicodeDecodeError, ValueError):
        return
    if recorded and Path(recorded).resolve() != opts.plan_path.resolve():
        return

    try:
        _ensure_safe_conduct_dir(opts.repo_root)
        _ensure_safe_fs_path(sp, expect_dir=False)
        legacy.rename(sp)
    except (FileNotFoundError, FileExistsError, OSError, UnsafeConductPathError):
        # Concurrent migrator or symlink races: bail. The next load will
        # observe whichever file landed at sp.
        return
    legacy_lock = legacy.with_suffix(legacy.suffix + ".lock")
    if legacy_lock.exists():
        try:
            legacy_lock.unlink()
        except OSError:
            pass


def _load_or_init_state(opts: ConductOptions) -> dict:
    _migrate_legacy_state_file(opts)
    sp = _state_path(opts)
    if sp.exists():
        state = json.loads(sp.read_text())
        # Backfill keys that older state files may be missing so the on-disk
        # schema converges to what SKILL.md documents. Persist immediately so
        # a crash before the next write does not leave backfill-in-memory only.
        mutated = False
        if "plan_content_hash" not in state:
            state["plan_content_hash"] = compute_plan_hash(opts.plan_path)
            mutated = True
        if "last_summary" not in state:
            state["last_summary"] = ""
            mutated = True
        if opts.resume:
            state["resume_base_sha"] = _head_sha(opts.repo_root)
            state["status"] = "running"
            mutated = True
        if mutated:
            _persist_state(opts, state)
        return state
    state = {
        "plan_path": str(opts.plan_path),
        "plan_content_hash": compute_plan_hash(opts.plan_path),
        "base_sha": _head_sha(opts.repo_root),
        "phase_index": 0,
        "completed_phases": [],
        "last_summary": "",
        "iteration_count": 0,
        "status": "running",
        "blocker": None,
    }
    _persist_state(opts, state)
    return state


def _persist_state(opts: ConductOptions, state: dict) -> None:
    sp = _state_path(opts)
    _ensure_safe_conduct_dir(opts.repo_root)
    _safe_write_text(sp, json.dumps(state, indent=2))


# ---------------------------------------------------------------------------
# Per-phase
# ---------------------------------------------------------------------------


def _spawn_strategy(phase: Phase) -> tuple[str, str]:
    """Return ('parallel'|'sequential', reason)."""
    if not phase.impl_files or not phase.test_files:
        return "sequential", "missing slot"
    if files_overlap(phase.impl_files, phase.test_files):
        return "sequential", "file overlap"
    return "parallel", "disjoint paths"


def _resolve_test_cmd(opts: ConductOptions, phase: Phase) -> Optional[str]:
    if opts.test_cmd_override:
        return opts.test_cmd_override
    if phase.test_command:
        return phase.test_command
    return _repo_default_test_cmd(opts.repo_root)


def detect_lint_command(repo_root: Path) -> Optional[list[str]]:
    """SKILL.md Preflight Step 3 probe.

    Returns the argv of the first available lint check that applies to this
    repo, or ``None`` if none apply. Pure detection — does not run anything,
    so tests can verify the probe order without invoking real subprocesses.

    Probe order:
      1. ``pre-commit run --all-files`` — needs ``.pre-commit-config.yaml`` and the binary on PATH.
      2. ``make lint`` — needs a ``Makefile`` with a ``lint:`` target and ``make`` on PATH.
      3. ``npm run lint`` — needs ``package.json`` with ``scripts.lint`` and ``npm`` on PATH.
      4. ``ruff check .`` — needs ``ruff`` on PATH and at least one Python signal in repo
         (``pyproject.toml`` or any ``*.py`` file at the top level).
    """
    pcc = repo_root / ".pre-commit-config.yaml"
    if pcc.exists() and shutil.which("pre-commit"):
        return ["pre-commit", "run", "--all-files"]

    makefile = repo_root / "Makefile"
    if makefile.exists() and shutil.which("make"):
        try:
            text = makefile.read_text()
        except OSError:
            text = ""
        for line in text.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("lint:") or stripped.startswith("lint :"):
                return ["make", "lint"]

    pkg = repo_root / "package.json"
    if pkg.exists() and shutil.which("npm"):
        try:
            text = pkg.read_text()
        except OSError:
            text = ""
        if '"scripts"' in text and '"lint"' in text:
            return ["npm", "run", "lint"]

    if shutil.which("ruff"):
        if (repo_root / "pyproject.toml").exists() or any(repo_root.glob("*.py")):
            return ["ruff", "check", "."]

    return None


def default_lint_check(repo_root: Path) -> Optional[str]:
    """Run the first available lint check; return its diagnostic on failure.

    Returns ``None`` when no lint tool is available (skip per SKILL.md) OR
    when the configured check passed. Returns the captured stdout+stderr tail
    when the check exits non-zero — that text becomes the preflight diagnostic.
    """
    argv = detect_lint_command(repo_root)
    if argv is None:
        return None
    proc = subprocess.run(
        argv, cwd=str(repo_root), capture_output=True, text=True, check=False
    )
    if proc.returncode == 0:
        return None
    output = (proc.stdout or "") + (proc.stderr or "")
    cmd = " ".join(argv)
    return f"{cmd} (exit {proc.returncode}):\n{output[-2000:]}"


def _repo_default_test_cmd(repo_root: Path) -> Optional[str]:
    """SKILL.md Step 5 fallback chain step 3.

    Probes in this order:
      1. ``package.json`` with a ``scripts.test`` entry → ``npm test``.
      2. ``pyproject.toml`` with ``[tool.pytest.ini_options]`` → ``uvx pytest``.
      3. ``Makefile`` with a ``test:`` target → ``make test``.

    Returns ``None`` if none match; the caller treats that as skip-with-warning.
    Detection is intentionally string-level (no toml/json parse) so the function
    has zero stdlib-only dependencies and stays safe on partially-valid files.
    """
    pkg = repo_root / "package.json"
    if pkg.exists():
        try:
            text = pkg.read_text()
        except OSError:
            text = ""
        if '"scripts"' in text and '"test"' in text:
            return "npm test"

    pyproject = repo_root / "pyproject.toml"
    if pyproject.exists():
        try:
            text = pyproject.read_text()
        except OSError:
            text = ""
        if "[tool.pytest.ini_options]" in text:
            return "uvx pytest"

    makefile = repo_root / "Makefile"
    if makefile.exists():
        try:
            text = makefile.read_text()
        except OSError:
            text = ""
        for line in text.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("test:") or stripped.startswith("test :"):
                return "make test"
    return None


def _phase_baseline(state: dict) -> str:
    """Baseline SHA for the rogue-commit comparison.

    Per SKILL.md Step 8: ``resume_base_sha`` if this run started from --resume,
    otherwise the most recent completed phase with a concrete commit_sha (or
    base_sha for phase 1). Entries with ``commit_sha: None`` (no-op phases,
    rogue-commit handbacks) are skipped so they don't poison the baseline.
    """
    if state.get("resume_base_sha"):
        return state["resume_base_sha"]
    for entry in reversed(state.get("completed_phases") or []):
        sha = entry.get("commit_sha")
        if sha:
            return sha
    return state["base_sha"]


def _run_phase(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
) -> ConductResult:
    state["iteration_count"] = 0
    state["current_phase_title"] = phase.title
    # Keep on-disk phase_index aligned with the number of already-completed
    # phases so external readers see a live counter that matches SKILL.md's
    # documented schema.
    state["phase_index"] = len(state.get("completed_phases") or [])
    _persist_state(opts, state)

    strategy, strategy_reason = _spawn_strategy(phase)
    base_sha = _phase_baseline(state)
    test_cmd = _resolve_test_cmd(opts, phase)

    iteration = 0
    prior_diff = ""
    test_failures = ""
    respawn_role = "implementer"  # may flip to test-writer for one iteration

    while True:
        req = SpawnRequest(
            role=respawn_role,
            plan_path=str(opts.plan_path),
            phase_position=phase.position,
            phase_label=phase.label,
            phase_title=phase.title,
            iteration=iteration,
            base_sha=base_sha,
            prior_diff=prior_diff,
            test_failures=test_failures,
        )

        # On the first iteration we may also spawn the test-writer (parallel
        # or sequential per strategy). For fix-loop iterations we only respawn
        # one role per the SKILL.md algorithm.
        impl_text: Optional[str] = None
        test_text: Optional[str] = None

        if iteration == 0:
            # In an LLM-driven run the parallel-vs-sequential signal tells main
            # Claude whether to issue both Agent calls in one message (parallel)
            # or issue the implementer first and the test-writer after
            # (sequential, when paths overlap). From the harness's perspective
            # both calls still reach opts.spawn; the ordering distinction is an
            # LLM-layer concern, not a module-layer one.
            impl_text = opts.spawn(req)
            test_req = SpawnRequest(
                role="test-writer",
                plan_path=req.plan_path,
                phase_position=req.phase_position,
                phase_label=req.phase_label,
                phase_title=req.phase_title,
                iteration=0,
                base_sha=req.base_sha,
            )
            test_text = opts.spawn(test_req)
        else:
            text = opts.spawn(req)
            if respawn_role == "implementer":
                impl_text = text
            else:
                test_text = text

        # Parse reports (every text we got).
        try:
            if impl_text is not None:
                impl_report = parse_report(impl_text, "implementer")
            else:
                impl_report = None
            if test_text is not None:
                parse_report(test_text, "test-writer")
        except SchemaError as exc:
            state["status"] = "schema_error"
            state["blocker"] = str(exc)
            _persist_state(opts, state)
            return ConductResult(
                status="schema_error",
                state=state,
                summary=f"phase {phase.label} schema error: {exc}",
                diagnostic=str(exc),
            )

        # Resolve test command. If absent and no override → skip-with-warning,
        # go straight to commit. Drain any preflight-level warnings queued in
        # state so the user sees them on the first handback only.
        warnings: list[str] = list(state.pop("warnings_for_next_handback", []))
        if test_cmd is None:
            warnings.append("no test command; skipped tests")
            commit_outcome = _commit_phase(opts, state, phase, base_sha, warnings)
            if commit_outcome.status != "running":
                return commit_outcome
            return _handback(
                opts,
                state,
                phase,
                "skipped",
                iteration,
                strategy,
                strategy_reason,
                warnings,
            )

        # Step 5: run tests.
        result = opts.test_runner(test_cmd, opts.test_timeout)
        if result.returncode == 0 and not result.timed_out:
            # Step 5b: optional Validation cmd. Runs after tests pass, before
            # the boundary commit. Failure = handback, NOT fix-loop — validation
            # typically exercises live-data behaviour an implementer cannot
            # auto-repair (reprocess a transcript, hit a staging API, etc.).
            if phase.validation_command:
                vresult = opts.test_runner(phase.validation_command, opts.test_timeout)
                if vresult.returncode != 0 or vresult.timed_out:
                    state["status"] = "awaiting_user"
                    state["blocker"] = f"Phase {phase.label} validation failed"
                    _persist_state(opts, state)
                    return ConductResult(
                        status="awaiting_user",
                        state=state,
                        summary=state["blocker"],
                        diagnostic=vresult.output[-2000:],
                    )
                warnings.append("validation passed")
            commit_outcome = _commit_phase(opts, state, phase, base_sha, warnings)
            if commit_outcome.status != "running":
                return commit_outcome
            return _handback(
                opts,
                state,
                phase,
                "passed",
                iteration,
                strategy,
                strategy_reason,
                warnings,
            )

        # Step 6: fix loop.
        state["iteration_count"] += 1
        _persist_state(opts, state)
        if state["iteration_count"] > opts.max_iterations:
            state["status"] = "blocked"
            state["blocker"] = (
                f"Phase {phase.label} stalled after {opts.max_iterations} iterations"
            )
            _persist_state(opts, state)
            return ConductResult(
                status="blocked",
                state=state,
                summary=state["blocker"],
                diagnostic=result.output[-2000:],
            )

        # Capture staged diff, reset index, then choose respawn role.
        prior_diff = _staged_diff(opts.repo_root)
        _reset_index(opts.repo_root)
        test_failures = result.output

        flag_mismatch = bool(
            impl_report
            and impl_report.get("flags", {}).get("test_contract_mismatch") is True
        )
        respawn_role = "test-writer" if flag_mismatch else "implementer"
        iteration = state["iteration_count"]


def _commit_phase(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
    base_sha: str,
    warnings: list[str],
) -> ConductResult:
    """Step 8: rogue-commit detection + boundary commit.

    Returns ConductResult with status='running' on success (caller continues to
    handback), or a terminal status on rogue/hook failure.
    """
    head_now = _head_sha(opts.repo_root)
    if head_now != base_sha:
        state["status"] = "awaiting_user"
        state["blocker"] = "rogue commit"
        completed = {
            "index": phase.position,
            "label": phase.label,
            "title": phase.title,
            # HEAD has advanced to head_now by the subagent's rogue commit.
            # Leave commit_sha=None to signal "conductor did not itself
            # commit" (harness tests and state readers rely on this), but the
            # baseline for any later phase walks back to a concrete SHA via
            # `_phase_baseline`'s skip-None rule.
            "commit_sha": None,
            "rogue_commit_sha": head_now,
            "tests": "passed-but-rogue",
            "iterations": state["iteration_count"],
        }
        state.setdefault("completed_phases", []).append(completed)
        _persist_state(opts, state)
        return ConductResult(
            status="awaiting_user",
            state=state,
            summary=f"phase {phase.label}: rogue commit {head_now}",
            diagnostic=f"subagent committed {head_now}; conductor refused to stack a second commit",
        )

    # If nothing is staged (skip-tests on a no-op phase), still boundary-commit
    # with --allow-empty? SKILL.md doesn't say; we choose to skip the commit
    # cleanly when there's nothing to commit and warn instead.
    if not _staged_diff(opts.repo_root):
        warnings.append("no staged changes; skipping commit")
        completed = {
            "index": phase.position,
            "label": phase.label,
            "title": phase.title,
            # HEAD is unchanged; record it so the next phase's baseline
            # falls back to the correct SHA rather than None.
            "commit_sha": head_now,
            "tests": "passed",
            "iterations": state["iteration_count"],
            "no_op": True,
        }
        state.setdefault("completed_phases", []).append(completed)
        state.pop("resume_base_sha", None)
        return ConductResult(status="running", state=state, summary="")

    commit_msg = f"conduct: phase {phase.label} — {phase.title}"
    proc = _git(["commit", "-m", commit_msg], opts.repo_root, check=False)

    # Formatter-hook retry: if a pre-commit hook modified tracked files in
    # place (black, ruff --fix, prettier), the tree now has unstaged
    # modifications on files we originally staged. Re-stage those paths and
    # retry the commit once before routing to the fix loop. Scope is limited
    # to tracked modifications ONLY — we do NOT sweep in untracked files the
    # hook may have created, because that would also sweep in unrelated
    # worktree artefacts (scratch files, log output, prior incomplete work)
    # and can silently produce commits the user did not intend. Hooks that
    # emit genuinely new artefacts (codegen, lockfile generation) fall
    # through to the fix loop and surface the hook output to the implementer,
    # which is the correct recovery path.
    if proc.returncode != 0:
        unstaged = _git(
            ["diff", "--name-only"], opts.repo_root, check=False
        ).stdout.strip()
        if unstaged:
            warnings.append(
                "pre-commit hook modified tracked files; re-staged and retrying"
            )
            _git(["add", "-u"], opts.repo_root, check=False)
            proc = _git(["commit", "-m", commit_msg], opts.repo_root, check=False)

    if proc.returncode != 0:
        # Pre-commit hook failure → route into fix loop.
        state["iteration_count"] += 1
        _persist_state(opts, state)
        if state["iteration_count"] > opts.max_iterations:
            state["status"] = "blocked"
            state["blocker"] = (
                f"Phase {phase.label} stalled at boundary commit after "
                f"{opts.max_iterations} iterations"
            )
            _persist_state(opts, state)
            return ConductResult(
                status="blocked",
                state=state,
                summary=state["blocker"],
                diagnostic=(proc.stdout + proc.stderr)[-2000:],
            )
        # Signal the caller to re-enter the loop. We do this by returning a
        # special marker the caller checks. But simpler: raise a sentinel.
        raise _CommitHookFailure(output=proc.stdout + proc.stderr)

    new_head = _head_sha(opts.repo_root)
    completed = {
        "index": phase.position,
        "label": phase.label,
        "title": phase.title,
        "commit_sha": new_head,
        "tests": "passed",
        "iterations": state["iteration_count"],
    }
    state.setdefault("completed_phases", []).append(completed)
    # Clear resume_base_sha after the first successful commit of a resumed
    # run. SKILL.md Step 8: subsequent phases in the same process use the
    # previous phase's commit_sha as their baseline. Leaving resume_base_sha
    # set across phases would make a clean phase 2 trip the rogue-commit check
    # (HEAD has advanced past the resume baseline by phase 1's own commit).
    state.pop("resume_base_sha", None)
    return ConductResult(status="running", state=state, summary="")


class _CommitHookFailure(Exception):
    def __init__(self, output: str) -> None:
        self.output = output


def _handback(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
    test_status: str,
    iteration: int,
    strategy: str,
    strategy_reason: str,
    warnings: list[str],
) -> ConductResult:
    summary = (
        f"Phase {phase.label}: {phase.title}\n"
        f"  Spawn: {strategy} ({strategy_reason})\n"
        f"  Tests: {test_status}\n"
        f"  Iterations: {iteration}\n"
        + ("".join(f"  Warning: {w}\n" for w in warnings) if warnings else "")
    )
    state["status"] = "awaiting_user"
    state["last_summary"] = summary
    _persist_state(opts, state)
    next_cmd = f"Run: /conduct --resume {opts.plan_path}"
    result = ConductResult(
        status="awaiting_user",
        state=state,
        summary=summary,
        next_command=next_cmd,
    )
    if opts.on_handback:
        opts.on_handback(state)
    return result


# ---------------------------------------------------------------------------
# Top-level entry
# ---------------------------------------------------------------------------


def conduct(opts: ConductOptions) -> ConductResult:
    """Run preflight + the next unfinished phase, then hand back.

    Mirrors SKILL.md Step 9: every phase boundary returns control to the user.
    Tests drive multi-phase runs by re-invoking with ``resume=True``.
    """
    pre = run_preflight(opts)
    if pre is not None:
        return pre

    sp = _state_path(opts)
    try:
        _ensure_safe_conduct_dir(opts.repo_root)
        _ensure_safe_fs_path(sp, expect_dir=False)
    except UnsafeConductPathError as exc:
        return ConductResult(
            status="preflight_fail",
            state={},
            summary="unsafe conduct state path",
            diagnostic=str(exc),
        )
    lock = StateLock(str(sp.with_suffix(sp.suffix + ".lock")))
    with lock:
        state = _load_or_init_state(opts)

        plan_text = opts.plan_path.read_text()
        phases = [p for p in parse_phases(plan_text) if not p.is_complete]

        # Plan-slot coverage warning (emitted at most once per run). If no
        # unfinished phase declares any of Impl files: / Test files: /
        # Test command: / Validation cmd:, the conductor will fall through to
        # degraded mode (sequential spawn + test fallback) for every phase.
        # That's a valid choice but often an oversight in the plan template.
        internal = state.setdefault("_internal", {})
        if (
            phases
            and not any(p.has_any_slot() for p in phases)
            and not internal.get("slot_warning_shown")
        ):
            internal["slot_warning_shown"] = True
            state.setdefault("warnings_for_next_handback", []).append(
                "no phase declares Impl files: / Test files: / Test command: / "
                "Validation cmd: slots — running in degraded mode. "
                "Fill these per-phase in the plan (see /dev-plan) to enable "
                "parallel spawn and real test runs."
            )

        # phase_index in state is the count of completed phases.
        idx = len(state.get("completed_phases", []))
        if idx >= len(phases):
            state["status"] = "complete"
            _persist_state(opts, state)
            return ConductResult(
                status="complete", state=state, summary="All phases complete"
            )

        phase = phases[idx]
        try:
            return _run_phase(opts, state, phase)
        except _CommitHookFailure as hook_fail:
            # Re-enter the loop with hook output as the failure context. Easiest
            # way is recursion with the failure carried via state — but state
            # already holds iteration_count; we pass the failure text through
            # by routing back into _run_phase with prior_diff / test_failures
            # set on the next request. To keep the implementation simple we
            # adopt an explicit retry here.
            return _retry_after_hook_failure(opts, state, phase, hook_fail.output)


def _retry_after_hook_failure(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
    hook_output: str,
) -> ConductResult:
    """Respawn implementer with hook output as test_failures, then re-enter.

    SKILL.md Step 8.3: pre-commit hook failure routes back into Step 6 as a
    fix-loop iteration. iteration_count was already incremented before raising.
    """
    base_sha = _phase_baseline(state)
    iteration = state["iteration_count"]
    prior_diff = _staged_diff(opts.repo_root)
    _reset_index(opts.repo_root)

    respawn_role = "implementer"
    while True:
        req = SpawnRequest(
            role=respawn_role,
            plan_path=str(opts.plan_path),
            phase_position=phase.position,
            phase_label=phase.label,
            phase_title=phase.title,
            iteration=iteration,
            base_sha=base_sha,
            prior_diff=prior_diff,
            test_failures=hook_output,
        )
        text = opts.spawn(req)
        try:
            report = parse_report(text, respawn_role)
        except SchemaError as exc:
            state["status"] = "schema_error"
            state["blocker"] = str(exc)
            _persist_state(opts, state)
            return ConductResult(status="schema_error", state=state, summary=str(exc))
        # SKILL.md Step 6: if implementer flagged test_contract_mismatch, the
        # next iteration respawns the test-writer instead.
        if respawn_role == "implementer" and report.get("flags", {}).get(
            "test_contract_mismatch"
        ):
            respawn_role = "test-writer"
        else:
            respawn_role = "implementer"

        # Tests
        test_cmd = _resolve_test_cmd(opts, phase)
        if test_cmd is not None:
            result = opts.test_runner(test_cmd, opts.test_timeout)
            if result.returncode != 0 or result.timed_out:
                state["iteration_count"] += 1
                _persist_state(opts, state)
                if state["iteration_count"] > opts.max_iterations:
                    state["status"] = "blocked"
                    state["blocker"] = (
                        f"Phase {phase.label} stalled after {opts.max_iterations} iterations"
                    )
                    _persist_state(opts, state)
                    return ConductResult(
                        status="blocked", state=state, summary=state["blocker"]
                    )
                prior_diff = _staged_diff(opts.repo_root)
                _reset_index(opts.repo_root)
                hook_output = result.output
                iteration = state["iteration_count"]
                continue

        warnings: list[str] = []
        if test_cmd is None:
            warnings.append("no test command; skipped tests")
        try:
            commit_outcome = _commit_phase(opts, state, phase, base_sha, warnings)
        except _CommitHookFailure as exc:
            prior_diff = _staged_diff(opts.repo_root)
            _reset_index(opts.repo_root)
            hook_output = exc.output
            iteration = state["iteration_count"]
            continue
        if commit_outcome.status != "running":
            return commit_outcome
        return _handback(
            opts,
            state,
            phase,
            "passed",
            iteration,
            "sequential",
            "post-hook-fix",
            warnings,
        )


# ---------------------------------------------------------------------------
# Pause / abort helpers
# ---------------------------------------------------------------------------


def pause_phase(opts: ConductOptions) -> ConductResult:
    """`--pause-phase`: stash work, mark state paused, exit."""
    sp = _state_path(opts)
    try:
        _ensure_safe_fs_path(sp, expect_dir=False)
    except UnsafeConductPathError as exc:
        return ConductResult(
            status="blocked",
            state={},
            summary="unsafe conduct state path",
            diagnostic=str(exc),
        )
    if not sp.exists():
        return ConductResult(status="awaiting_user", state={}, summary="no active run")
    lock = StateLock(str(sp.with_suffix(sp.suffix + ".lock")))
    with lock:
        state = json.loads(sp.read_text())
        label = state.get("current_phase_title", "?")
        msg = f"conduct-pause-phase-{label}"
        _git(["stash", "push", "-u", "-m", msg], opts.repo_root, check=False)
        state["status"] = "paused"
        _persist_state(opts, state)
        return ConductResult(status="paused", state=state, summary=f"paused: {msg}")


def abort_run(opts: ConductOptions) -> ConductResult:
    """`--abort-run`: delete state plus any stale lockfile/lockdir. No git ops, no stash."""
    sp = _state_path(opts)
    lockfile = sp.with_suffix(sp.suffix + ".lock")
    lockdir = sp.with_suffix(sp.suffix + ".lock.lockdir")
    try:
        _ensure_safe_fs_path(sp, expect_dir=False)
        _ensure_safe_fs_path(lockfile, expect_dir=False)
        _ensure_safe_fs_path(lockdir, expect_dir=True)
    except UnsafeConductPathError as exc:
        return ConductResult(
            status="blocked",
            state={},
            summary="unsafe conduct state path",
            diagnostic=str(exc),
        )
    # Acquire the lock while we tear down so we don't race with a running
    # conductor. We delete the lockfile afterwards, which is safe because
    # the StateLock context manager has already released the fd/lockdir by
    # the time control leaves the `with` block.
    if sp.exists() and lockfile.exists():
        try:
            with StateLock(str(lockfile)):
                sp.unlink()
        except Exception:
            if sp.exists():
                sp.unlink()
    elif sp.exists():
        sp.unlink()
    if lockfile.exists():
        lockfile.unlink()
    if lockdir.exists():
        pid_file = lockdir / "pid"
        if pid_file.exists():
            pid_file.unlink()
        lockdir.rmdir()
    return ConductResult(status="aborted", state={}, summary="state deleted")
