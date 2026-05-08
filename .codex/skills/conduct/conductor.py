"""In-process conductor implementation of the SKILL.md per-phase algorithm.

This module exists primarily as a deterministic test harness. Real /conduct
runs are driven by main Codex inlining the SKILL.md algorithm with
``spawn_agent`` / ``wait_agent`` / ``close_agent`` as the worker-control
primitive — but that path is impossible to unit-test because real delegated
agents cost budget and produce non-deterministic output.

Here we factor the loop into a function with three injectable seams:

- ``spawn_fn(SpawnRequest) -> str`` — replaces delegated-agent orchestration.
  Receives a
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
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional

from .lock import LockError, StateLock, lock_is_held
from .marker import compute_plan_hash, marker_is_stale, read_marker, write_marker
from .parser import Phase, files_overlap, parse_phases
from .runner import TestResult, run_tests
from .schema import SchemaError, parse_report


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


DELEGATION_UNAVAILABLE_MESSAGE = (
    "Delegated subagents unavailable in this Codex runtime; the conduct skill requires "
    "spawn_agent, wait_agent, and close_agent support."
)


class UnsafeConductPathError(RuntimeError):
    pass


STATE_SCHEMA_VERSION = 2


def delegation_unavailable_result(plan_path: str | Path) -> ConductResult:
    """Hard-stop result for runtimes that cannot delegate phase workers."""
    return ConductResult(
        status="preflight_fail",
        state={},
        summary="delegation unavailable",
        diagnostic=(
            f"{DELEGATION_UNAVAILABLE_MESSAGE}\n"
            f"Run this skill in a Codex session with agent delegation support: /conduct {plan_path}"
        ),
    )


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


def _staged_paths(repo_root: Path) -> list[str]:
    output = _git(["diff", "--cached", "--name-only", "--diff-filter=ACMR"], repo_root).stdout
    return [line.strip() for line in output.splitlines() if line.strip()]


def _tracked_modified_paths(repo_root: Path) -> list[str]:
    output = _git(["diff", "--name-only"], repo_root, check=False).stdout
    return [line.strip() for line in output.splitlines() if line.strip()]


def _reset_index(repo_root: Path) -> None:
    _git(["reset"], repo_root)


_REDACTION_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"(?im)\b(authorization\s*:\s*bearer)\s+\S+"),
        r"\1 [REDACTED]",
    ),
    (
        re.compile(r"(?im)\b(api[_-]?key|token|secret|password)\b\s*[:=]\s*\S+"),
        r"\1=[REDACTED]",
    ),
)


def _summarize_failure_output(output: str, *, max_chars: int = 1200, max_lines: int = 20) -> str:
    redacted = output
    for pattern, replacement in _REDACTION_PATTERNS:
        redacted = pattern.sub(replacement, redacted)
    lines = redacted.splitlines()
    if len(lines) > max_lines:
        redacted = "\n".join(["[...]", *lines[-max_lines:]])
    redacted = redacted.strip()
    if len(redacted) > max_chars:
        redacted = "[...]\n" + redacted[-max_chars:]
    return redacted or "(no output captured)"


def _diagnostic_tail(output: str, *, max_chars: int = 2000) -> str:
    return _summarize_failure_output(output, max_chars=max_chars, max_lines=40)


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
        if opts.resume:
            old_iso, old_sha = marker
            new_sha = write_marker(opts.plan_path)
            print(
                "conduct: review marker auto-refreshed on resume "
                f"(was {old_iso} @ {old_sha[:12]}, now @ {new_sha[:12]})",
                file=sys.stderr,
            )
        else:
            return ConductResult(
                status="preflight_fail",
                state={},
                summary="stale review marker",
                diagnostic=f"Run: /review-plan {opts.plan_path}",
            )

    lint_diag = opts.lint_check() if opts.lint_check is not None else None
    if lint_diag:
        return ConductResult(
            status="preflight_fail",
            state={},
            summary="pre-existing lint failure",
            diagnostic=(
                "Tree has pre-existing lint/hook failures; fix them before running this skill\n"
                + _diagnostic_tail(lint_diag)
            ),
        )
    return None


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


def _state_path(opts: ConductOptions) -> Path:
    try:
        rel_plan = opts.plan_path.resolve().relative_to(opts.repo_root.resolve()).as_posix()
    except ValueError:
        rel_plan = opts.plan_path.resolve().as_posix()
    digest = hashlib.sha1(rel_plan.encode("utf-8")).hexdigest()[:12]
    return opts.repo_root / ".conduct" / f"state-{opts.plan_path.stem}-{digest}.json"


def _ensure_safe_conduct_dir(repo_root: Path) -> Path:
    conduct_dir = repo_root / ".conduct"
    if conduct_dir.exists():
        if conduct_dir.is_symlink() or not conduct_dir.is_dir():
            raise UnsafeConductPathError(f"unsafe conduct dir: {conduct_dir}")
        return conduct_dir
    conduct_dir.mkdir(parents=True, exist_ok=True)
    if conduct_dir.is_symlink() or not conduct_dir.is_dir():
        raise UnsafeConductPathError(f"unsafe conduct dir: {conduct_dir}")
    return conduct_dir


def _ensure_safe_fs_path(path: Path, *, expect_dir: bool | None = None) -> None:
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


def _conduct_path_result(status: str, summary: str, path: Path) -> ConductResult:
    return ConductResult(
        status=status,
        state={},
        summary=summary,
        diagnostic=f"Unsafe .conduct filesystem path: {path}",
    )


def _validate_state_shape(state: dict) -> dict:
    if not isinstance(state.get("schema_version"), int):
        raise UnsafeConductPathError("invalid conduct state: schema_version must be an int")
    if not isinstance(state.get("completed_phases"), list):
        raise UnsafeConductPathError("invalid conduct state: completed_phases must be a list")
    if "paused_stash_rev" in state and state["paused_stash_rev"] is not None and not isinstance(
        state["paused_stash_rev"], str
    ):
        raise UnsafeConductPathError("invalid conduct state: paused_stash_rev must be a string")
    if not isinstance(state.get("phase_index"), int):
        raise UnsafeConductPathError("invalid conduct state: phase_index must be an int")
    return state


def _normalize_loaded_state(state: dict) -> dict:
    normalized = dict(state)
    normalized.setdefault("phase_index", len(normalized.get("completed_phases") or []))
    normalized.setdefault("current_phase_title", "")
    normalized.setdefault("completed_phases", [])
    normalized.setdefault("last_summary", "")
    normalized.setdefault("iteration_count", 0)
    normalized.setdefault("status", "running")
    normalized.setdefault("blocker", None)
    normalized.setdefault("paused_stash_rev", None)
    normalized["schema_version"] = STATE_SCHEMA_VERSION
    return _validate_state_shape(normalized)


def _migrate_loaded_state(state: dict) -> dict:
    version = state.get("schema_version", 0)
    if not isinstance(version, int):
        raise UnsafeConductPathError("invalid conduct state: schema_version must be an int")
    if version > STATE_SCHEMA_VERSION:
        raise UnsafeConductPathError(
            f"unsupported conduct state schema_version: {version}"
        )
    migrated = dict(state)
    if version < 1:
        migrated["schema_version"] = 1
    if version < 2:
        migrated.setdefault("paused_stash_rev", None)
        migrated["schema_version"] = 2
    return migrated


def _init_state(opts: ConductOptions, plan_hash: str) -> dict:
    return {
        "schema_version": STATE_SCHEMA_VERSION,
        "plan_path": str(opts.plan_path),
        "plan_content_hash": plan_hash,
        "base_sha": _head_sha(opts.repo_root),
        "phase_index": 0,
        "current_phase_title": "",
        "completed_phases": [],
        "last_summary": "",
        "iteration_count": 0,
        "status": "running",
        "blocker": None,
        "paused_stash_rev": None,
    }


def _load_or_init_state(opts: ConductOptions, plan_hash: str) -> tuple[dict, bool]:
    sp = _state_path(opts)
    if sp.exists():
        state = _normalize_loaded_state(_migrate_loaded_state(json.loads(sp.read_text())))
        if opts.resume:
            # Preflight has already validated that the current plan hash
            # matches the marker, whether the marker was auto-refreshed here
            # or manually refreshed between conduct sessions. Resync the
            # stored hash so the resume gate tracks the reviewed plan.
            if state["plan_content_hash"] != plan_hash:
                state["plan_content_hash"] = plan_hash
        return state, True
    return _init_state(opts, plan_hash), False


def _state_matches_plan(state: dict, opts: ConductOptions, plan_hash: str) -> bool:
    plan_path = state.get("plan_path")
    if not isinstance(plan_path, str):
        return False
    if Path(plan_path).resolve() != opts.plan_path.resolve():
        return False
    return state.get("plan_content_hash") == plan_hash


def _resume_required_result(opts: ConductOptions, state: dict) -> ConductResult:
    completed = len(state.get("completed_phases") or [])
    summary = (
        f"Existing conduct state found for {opts.plan_path}\n"
        f"  Status: {state.get('status', 'unknown')}\n"
        f"  Completed phases: {completed}"
    )
    if state.get("last_summary"):
        summary = f"{summary}\n{state['last_summary'].rstrip()}"
    return ConductResult(
        status="awaiting_user",
        state=state,
        summary=summary,
        next_command=f"Run: /conduct --resume {opts.plan_path}",
        diagnostic=f"Run: /conduct --abort-run {opts.plan_path}",
    )


def _state_mismatch_result(
    opts: ConductOptions, state: dict, current_plan_hash: str
) -> ConductResult:
    return ConductResult(
        status="preflight_fail",
        state=state,
        summary="state does not match current reviewed plan",
        diagnostic=(
            "Existing conduct state does not belong to the current reviewed plan.\n"
            f"Stored plan_path: {state.get('plan_path', '<missing>')}\n"
            f"Stored plan_content_hash: {state.get('plan_content_hash', '<missing>')}\n"
            f"Current plan_path: {opts.plan_path}\n"
            f"Current plan_content_hash: {current_plan_hash}\n"
            f"Run: /conduct --abort-run {opts.plan_path}"
        ),
    )


def _persist_state(opts: ConductOptions, state: dict) -> None:
    sp = _state_path(opts)
    _ensure_safe_conduct_dir(opts.repo_root)
    _safe_write_text(sp, json.dumps(state, indent=2))


def _latest_stash_rev(repo_root: Path) -> str | None:
    proc = _git(["stash", "list", "--format=%H", "-1"], repo_root, check=False)
    rev = proc.stdout.strip()
    return rev or None


def _stash_ref_for_rev(repo_root: Path, rev: str) -> str | None:
    proc = _git(["stash", "list", "--format=%gd%x00%H"], repo_root, check=False)
    for line in proc.stdout.splitlines():
        if not line:
            continue
        ref, _, sha = line.partition("\x00")
        if sha.strip() == rev:
            return ref.strip()
    return None


def _restore_paused_stash(opts: ConductOptions, state: dict) -> Optional[ConductResult]:
    if state.get("status") != "paused":
        return None
    stash_rev = state.get("paused_stash_rev")
    if stash_rev == "":
        return None
    if stash_rev is None:
        return ConductResult(
            status="blocked",
            state=state,
            summary="paused run missing stash metadata",
            diagnostic="Restore the paused stash manually or abort the run.",
        )
    stash_ref = _stash_ref_for_rev(opts.repo_root, stash_rev)
    if stash_ref is None:
        return ConductResult(
            status="blocked",
            state=state,
            summary="paused stash is no longer available",
            diagnostic=f"Missing stash rev: {stash_rev}",
        )
    apply_proc = _git(["stash", "apply", "--index", stash_ref], opts.repo_root, check=False)
    if apply_proc.returncode != 0:
        return ConductResult(
            status="blocked",
            state=state,
            summary="failed to restore paused stash",
            diagnostic=_diagnostic_tail((apply_proc.stdout or "") + (apply_proc.stderr or "")),
        )
    _git(["stash", "drop", stash_ref], opts.repo_root, check=False)
    state["paused_stash_rev"] = None
    return None


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


def _run_validation_if_present(
    opts: ConductOptions, state: dict, phase: Phase, warnings: list[str]
) -> Optional[ConductResult]:
    if not phase.validation_command:
        return None
    validation = opts.test_runner(phase.validation_command, opts.test_timeout)
    if validation.returncode != 0 or validation.timed_out:
        state["status"] = "awaiting_user"
        state["blocker"] = f"Phase {phase.label} validation failed"
        _persist_state(opts, state)
        return ConductResult(
            status="awaiting_user",
            state=state,
            summary=state["blocker"],
            diagnostic=_diagnostic_tail(validation.output),
        )
    warnings.append("validation passed")
    return None


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
         (``pyproject.toml`` or any tracked-source-style ``*.py`` file anywhere under the repo
         root other than ``.git`` internals).
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
        if (repo_root / "pyproject.toml").exists() or any(
            ".git" not in py.parts for py in repo_root.rglob("*.py")
        ):
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


def _worker_blocker_result(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
    *,
    impl_report: Optional[dict[str, Any]] = None,
    test_report: Optional[dict[str, Any]] = None,
) -> Optional[ConductResult]:
    if impl_report is not None:
        flags = impl_report.get("flags", {})
        if flags.get("blocked") is True:
            detail = flags.get("explanation") or impl_report.get("summary") or "implementer reported blocked"
            state["status"] = "blocked"
            state["blocker"] = f"Phase {phase.label} blocked by implementer: {detail}"
            state["last_summary"] = state["blocker"]
            _persist_state(opts, state)
            return ConductResult(
                status="blocked",
                state=state,
                summary=state["blocker"],
                diagnostic=str(detail),
            )

    if test_report is not None:
        flags = test_report.get("flags", {})
        clarification = flags.get("needs_impl_clarification")
        if flags.get("blocked") is True or clarification:
            detail = clarification or test_report.get("coverage_summary") or "test-writer reported blocked"
            state["status"] = "blocked"
            state["blocker"] = f"Phase {phase.label} blocked by test-writer: {detail}"
            state["last_summary"] = state["blocker"]
            _persist_state(opts, state)
            return ConductResult(
                status="blocked",
                state=state,
                summary=state["blocker"],
                diagnostic=str(detail),
            )

    return None


def _run_phase(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
    initial_warnings: Optional[list[str]] = None,
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
            impl_text = opts.spawn(req)
            if strategy == "parallel":
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
                test_report = parse_report(test_text, "test-writer")
            else:
                test_report = None
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

        block_result = _worker_blocker_result(
            opts, state, phase, impl_report=impl_report, test_report=test_report
        )
        if block_result is not None:
            return block_result

        # Resolve test command. If absent and no override → skip-with-warning,
        # go straight to commit.
        warnings: list[str] = list(initial_warnings or [])
        if test_cmd is None:
            warnings.append("no test command; skipped tests")
            validation_result = _run_validation_if_present(opts, state, phase, warnings)
            if validation_result is not None:
                return validation_result
            commit_outcome = _commit_phase(opts, state, phase, base_sha, warnings)
            if commit_outcome.status != "running":
                return commit_outcome
            return _handback(opts, state, phase, "skipped", iteration, strategy, strategy_reason, warnings)

        # Step 5: run tests.
        result = opts.test_runner(test_cmd, opts.test_timeout)
        if result.returncode == 0 and not result.timed_out:
            validation_result = _run_validation_if_present(opts, state, phase, warnings)
            if validation_result is not None:
                return validation_result
            commit_outcome = _commit_phase(opts, state, phase, base_sha, warnings)
            if commit_outcome.status != "running":
                return commit_outcome
            return _handback(opts, state, phase, "passed", iteration, strategy, strategy_reason, warnings)

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
                diagnostic=_diagnostic_tail(result.output),
            )

        # Capture staged diff, reset index, then choose respawn role.
        prior_diff = _staged_diff(opts.repo_root)
        flag_mismatch = bool(
            impl_report
            and impl_report.get("flags", {}).get("test_contract_mismatch") is True
        )
        if not flag_mismatch:
            _reset_index(opts.repo_root)
        test_failures = _summarize_failure_output(result.output)
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
        state["phase_index"] = len(state["completed_phases"])
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
        state["phase_index"] = len(state["completed_phases"])
        state.pop("resume_base_sha", None)
        return ConductResult(status="running", state=state, summary="")

    commit_msg = f"conduct: phase {phase.label} — {phase.title}"
    staged_paths = _staged_paths(opts.repo_root)
    proc = _git(["commit", "-m", commit_msg], opts.repo_root, check=False)
    if proc.returncode != 0:
        modified_paths = _tracked_modified_paths(opts.repo_root)
        if modified_paths:
            if staged_paths and set(modified_paths).issubset(set(staged_paths)):
                warnings.append("pre-commit hook modified files; re-staged and retrying")
                _git(["add", "-u", "--", *staged_paths], opts.repo_root, check=False)
                proc = _git(["commit", "-m", commit_msg], opts.repo_root, check=False)
            else:
                state["status"] = "awaiting_user"
                state["blocker"] = (
                    f"Phase {phase.label} pre-commit modified files outside the staged set"
                )
                state["last_summary"] = state["blocker"]
                _persist_state(opts, state)
                return ConductResult(
                    status="awaiting_user",
                    state=state,
                    summary=state["blocker"],
                    next_command=f"Run: /conduct --resume {opts.plan_path}",
                    diagnostic=_diagnostic_tail(
                        "Modified tracked files after failed commit:\n"
                        + "\n".join(modified_paths)
                        + "\n\nOriginally staged files:\n"
                        + "\n".join(staged_paths or ["<none>"])
                    ),
                )
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
                diagnostic=_diagnostic_tail((proc.stdout or "") + (proc.stderr or "")),
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
    state["phase_index"] = len(state["completed_phases"])
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
    state["status"] = "awaiting_user"
    summary = (
        f"Phase {phase.label}: {phase.title}\n"
        f"  Spawn: {strategy} ({strategy_reason})\n"
        f"  Tests: {test_status}\n"
        f"  Iterations: {iteration}\n"
        + ("".join(f"  Warning: {w}\n" for w in warnings) if warnings else "")
    )
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
    sp = _state_path(opts)
    try:
        _ensure_safe_conduct_dir(opts.repo_root)
        _ensure_safe_fs_path(sp, expect_dir=False)
    except UnsafeConductPathError:
        return _conduct_path_result("preflight_fail", "unsafe conduct state path", sp)
    lock = StateLock(str(sp.with_suffix(sp.suffix + ".lock")))
    with lock:
        if sp.exists():
            state = _normalize_loaded_state(_migrate_loaded_state(json.loads(sp.read_text())))
            state_exists = True
        else:
            state = {}
            state_exists = False
        if state_exists and not opts.resume:
            if state.get("status") == "paused" and not opts.plan_path.exists():
                return _resume_required_result(opts, state)
            pre = run_preflight(opts)
            if pre is not None:
                return pre
            plan_hash = compute_plan_hash(opts.plan_path)
            if not _state_matches_plan(state, opts, plan_hash):
                return _state_mismatch_result(opts, state, plan_hash)
            return _resume_required_result(opts, state)
        if state_exists and opts.resume:
            restore_result = _restore_paused_stash(opts, state)
            if restore_result is not None:
                return restore_result
        pre = run_preflight(opts)
        if pre is not None:
            return pre

        plan_hash = compute_plan_hash(opts.plan_path)
        if state_exists and opts.resume:
            # Preflight has already validated that the current plan hash
            # matches the marker, whether the marker was auto-refreshed here
            # or manually refreshed between conduct sessions. Resync the
            # stored hash so the resume gate tracks the reviewed plan.
            if state["plan_content_hash"] != plan_hash:
                state["plan_content_hash"] = plan_hash
        if state_exists and not _state_matches_plan(state, opts, plan_hash):
            return _state_mismatch_result(opts, state, plan_hash)
        if not state_exists:
            state = _init_state(opts, plan_hash)
        elif opts.resume:
            state["resume_base_sha"] = _head_sha(opts.repo_root)
            state["status"] = "running"
            _persist_state(opts, state)

        plan_text = opts.plan_path.read_text()
        phases = [p for p in parse_phases(plan_text) if not p.is_complete]
        # phase_index in state is the count of completed phases.
        idx = len(state.get("completed_phases", []))
        handback_warnings: list[str] = []
        if idx == 0 and phases and not any(p.has_any_slot() for p in phases):
            handback_warnings.append(
                "no phase declares Impl files: / Test files: / Test command: / "
                "Validation cmd: slots — running in degraded mode. "
                "Fill these per-phase in the plan (see /dev-plan) to enable "
                "parallel spawn and real test runs."
            )
        if idx >= len(phases):
            state["status"] = "complete"
            state["phase_index"] = len(phases)
            state["last_summary"] = "All phases complete"
            _persist_state(opts, state)
            return ConductResult(status="complete", state=state, summary="All phases complete")

        phase = phases[idx]
        try:
            return _run_phase(opts, state, phase, initial_warnings=handback_warnings)
        except _CommitHookFailure as hook_fail:
            # Re-enter the loop with hook output as the failure context. Easiest
            # way is recursion with the failure carried via state — but state
            # already holds iteration_count; we pass the failure text through
            # by routing back into _run_phase with prior_diff / test_failures
            # set on the next request. To keep the implementation simple we
            # adopt an explicit retry here.
            return _retry_after_hook_failure(
                opts,
                state,
                phase,
                hook_fail.output,
                initial_warnings=handback_warnings,
            )


def _retry_after_hook_failure(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
    hook_output: str,
    initial_warnings: Optional[list[str]] = None,
) -> ConductResult:
    """Respawn implementer with hook output as test_failures, then re-enter.

    SKILL.md Step 8.3: pre-commit hook failure routes back into Step 6 as a
    fix-loop iteration. iteration_count was already incremented before raising.
    """
    base_sha = _phase_baseline(state)
    iteration = state["iteration_count"]
    prior_diff = _staged_diff(opts.repo_root)
    _reset_index(opts.repo_root)
    failure_context = _summarize_failure_output(hook_output)

    respawn_role = "implementer"
    while True:
        validation_passed = False
        req = SpawnRequest(
            role=respawn_role,
            plan_path=str(opts.plan_path),
            phase_position=phase.position,
            phase_label=phase.label,
            phase_title=phase.title,
            iteration=iteration,
            base_sha=base_sha,
            prior_diff=prior_diff,
            test_failures=failure_context,
        )
        text = opts.spawn(req)
        try:
            report = parse_report(text, respawn_role)
        except SchemaError as exc:
            state["status"] = "schema_error"
            state["blocker"] = str(exc)
            _persist_state(opts, state)
            return ConductResult(status="schema_error", state=state, summary=str(exc))
        block_result = _worker_blocker_result(
            opts,
            state,
            phase,
            impl_report=report if respawn_role == "implementer" else None,
            test_report=report if respawn_role == "test-writer" else None,
        )
        if block_result is not None:
            return block_result
        # SKILL.md Step 6: if implementer flagged test_contract_mismatch, the
        # next iteration respawns the test-writer instead.
        next_respawn_role = "implementer"
        if respawn_role == "implementer" and report.get("flags", {}).get("test_contract_mismatch"):
            next_respawn_role = "test-writer"

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
                    return ConductResult(status="blocked", state=state, summary=state["blocker"])
                prior_diff = _staged_diff(opts.repo_root)
                if next_respawn_role != "test-writer":
                    _reset_index(opts.repo_root)
                failure_context = _summarize_failure_output(result.output)
                iteration = state["iteration_count"]
                respawn_role = next_respawn_role
                continue
        validation_result = _run_validation_if_present(opts, state, phase, [])
        if validation_result is not None:
            return validation_result
        validation_passed = bool(phase.validation_command)

        warnings: list[str] = list(initial_warnings or [])
        if validation_passed:
            warnings.append("validation passed")
        try:
            commit_outcome = _commit_phase(opts, state, phase, base_sha, warnings)
        except _CommitHookFailure as exc:
            prior_diff = _staged_diff(opts.repo_root)
            _reset_index(opts.repo_root)
            failure_context = _summarize_failure_output(exc.output)
            iteration = state["iteration_count"]
            respawn_role = "implementer"
            continue
        if commit_outcome.status != "running":
            return commit_outcome
        return _handback(
            opts, state, phase, "passed", iteration, "sequential", "post-hook-fix", warnings
        )


# ---------------------------------------------------------------------------
# Pause / abort helpers
# ---------------------------------------------------------------------------


def pause_phase(opts: ConductOptions) -> ConductResult:
    """`--pause-phase`: stash work, mark state paused, exit."""
    sp = _state_path(opts)
    try:
        _ensure_safe_conduct_dir(opts.repo_root)
        _ensure_safe_fs_path(sp, expect_dir=False)
    except UnsafeConductPathError:
        return _conduct_path_result("blocked", "unsafe conduct state path", sp)
    if not sp.exists():
        return ConductResult(status="awaiting_user", state={}, summary="no active run")
    lock = StateLock(str(sp.with_suffix(sp.suffix + ".lock")))
    with lock:
        state = json.loads(sp.read_text())
        label = state.get("current_phase_title", "?")
        msg = f"conduct-pause-phase-{label}"
        before_stash_rev = _latest_stash_rev(opts.repo_root)
        stash_proc = _git(
            ["stash", "push", "-u", "-m", msg, "--", ".", ":(exclude).conduct"],
            opts.repo_root,
            check=False,
        )
        if stash_proc.returncode != 0:
            return ConductResult(
                status="blocked",
                state=state,
                summary="failed to stash paused phase work",
                diagnostic=_diagnostic_tail((stash_proc.stdout or "") + (stash_proc.stderr or "")),
            )
        state["status"] = "paused"
        after_stash_rev = _latest_stash_rev(opts.repo_root)
        state["paused_stash_rev"] = after_stash_rev if after_stash_rev != before_stash_rev else ""
        _persist_state(opts, state)
        return ConductResult(status="paused", state=state, summary=f"paused: {msg}")


def abort_run(opts: ConductOptions) -> ConductResult:
    """`--abort-run`: delete state plus any stale lockfile/lockdir. No git ops, no stash."""
    sp = _state_path(opts)
    lockfile = sp.with_suffix(sp.suffix + ".lock")
    lockdir = sp.with_suffix(sp.suffix + ".lock.lockdir")
    try:
        _ensure_safe_conduct_dir(opts.repo_root)
        _ensure_safe_fs_path(sp, expect_dir=False)
        _ensure_safe_fs_path(lockfile, expect_dir=False)
        _ensure_safe_fs_path(lockdir, expect_dir=True)
    except UnsafeConductPathError:
        return _conduct_path_result("blocked", "unsafe conduct state path", sp)
    if lock_is_held(lockfile):
        return ConductResult(
            status="blocked",
            state={},
            summary="lock held by active conduct run",
            diagnostic="Retry after the active /conduct invocation exits.",
        )
    try:
        with StateLock(str(lockfile)):
            if sp.exists():
                sp.unlink()
    except LockError:
        return ConductResult(
            status="blocked",
            state={},
            summary="lock held by active conduct run",
            diagnostic="Retry after the active /conduct invocation exits.",
        )
    if lockfile.exists():
        lockfile.unlink()
    if lockdir.exists():
        for child in lockdir.iterdir():
            child.unlink()
        lockdir.rmdir()
    return ConductResult(status="aborted", state={}, summary="state deleted")
