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
import sys
import time
import warnings
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from ci_parity import detect_ci_entrypoint
from fileutil import (
    atomic_write_result_file as _atomic_write_result_file,
)
from fileutil import (
    ensure_under_directory,
    read_result_file,
    validate_plan_id,
)
from lock import StateLock
from marker import compute_plan_hash, marker_is_stale, read_marker, write_marker
from parser import Phase, files_overlap, parse_phases
from progress import compute_staged_diff_stat, iteration_signature
from runner import TestResult, run_tests
from schema import SchemaError, parse_report

# Plan-id derivations in this module are intentionally divergent:
#   _state_path()                       digests rel(plan_path, repo_root)  -> state-file naming, repo-scoped
#   _compute_cross_runtime_plan_id()    digests abs(plan_path)            -> cross-runtime handoff id (ci-parity gate)
#
# DO NOT use _state_path's digest for cross-runtime handoffs.
# DO NOT use _compute_cross_runtime_plan_id for state-file naming.
# See _compute_cross_runtime_plan_id's docstring for the worktree rationale.

# Runtime authorship for state files and locks. Claude-side conductor writes
# state-claude-<plan-stem>-<digest>.json; the Codex mirror writes
# state-codex-<...>. The two runtimes MUST NOT share a state file or lock; the
# author field on every state write is the diagnostics counterpart to this
# filename prefix.
_RUNTIME_AUTHOR = "claude"


# Module-level flag: emit the unknown-schema_version warning exactly once per
# Python process. Reset implicitly on a fresh process (e.g. a new --resume).
_UNKNOWN_SCHEMA_VERSION_WARNED: bool = False


# Tolerated-extras field set for the v2 "known subset" forward-compat contract.
# Future versions add only optional fields or fields with documented safe
# defaults; required-semantics fields require an ``incompatible_with_pre_vN:
# true`` marker that older loaders hard-fail on.
_V1_KNOWN_FIELDS = frozenset(
    {
        "plan_path",
        "plan_content_hash",
        "base_sha",
        "resume_base_sha",
        "phase_index",
        "current_phase_title",
        "completed_phases",
        "last_summary",
        "iteration_count",
        "status",
        "blocker",
        "warnings_for_next_handback",
        "_internal",
        # Tolerated extras introduced in Phase 1 (still schema_version=1):
        "stall_signatures",
        "stall_count",
        "plan_id",
        "state_author",
        "schema_version",
        # Phase 3 (schema_version=2) additions:
        "ci_parity_request",
        "ci_parity_request_written_at",
        "ci_parity_result",
        "ci_parity_dispatched",
        "ci_parity_missing_resume_count",
    }
)


# Phase 3 fields whose presence on a state write triggers a v2 serialization.
# When any of these are set, ``_persist_state`` stamps ``schema_version: 2``.
_PHASE_3_STATE_FIELDS = frozenset(
    {
        "ci_parity_request",
        "ci_parity_request_written_at",
        "ci_parity_result",
        "ci_parity_dispatched",
        "ci_parity_missing_resume_count",
    }
)


# Current state schema version this runtime knows how to write fully. Loader
# tolerates older / newer files per the forward-compat contract.
_STATE_SCHEMA_VERSION = 2


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


@dataclass
class CIParitySpawnRequest:
    """Payload handed to the CI-parity worker dispatch seam.

    Mirrors the placeholders in ``ci-parity-prompt.md`` so a scripted spawner
    (test injection) can render the prompt and execute the command in-process,
    while production dispatch goes through the main-runtime orchestrator (which
    reads these fields off ``ConductResult.request`` and writes the worker's
    final JSON to ``<repo-root>/.conduct/ci-parity-result-<plan-id>.json`` via
    ``_write_ci_parity_result``).
    """

    plan_path: str
    base_sha: str
    head_sha: str
    ci_entrypoint_kind: str  # 'just' | 'make' | 'npm' | 'cargo' | 'override'
    ci_cmd: str
    repo_root: str
    plan_id: str
    request_written_at_unix: float


SpawnFn = Callable[[SpawnRequest], str]
TestRunnerFn = Callable[[str, float], TestResult]
LintCheckFn = Callable[[], str | None]
HandbackFn = Callable[[dict], None]
CIParitySpawnFn = Callable[[CIParitySpawnRequest], str]


@dataclass
class ConductOptions:
    plan_path: Path
    repo_root: Path
    spawn: SpawnFn
    test_runner: TestRunnerFn = run_tests
    # If None, run_preflight runs ``default_lint_check(repo_root)`` — which
    # probes for pre-commit / make lint / npm run lint / ruff per SKILL.md
    # Step 3. Tests inject a stub to bypass real subprocess work.
    lint_check: LintCheckFn | None = None
    test_cmd_override: str | None = None
    test_timeout: float = 300.0
    max_iterations: int = 3
    # Progress-aware autonomous-runway cap. Default 8 leaves headroom for a
    # progressing phase while the legacy `max_iterations` (default 3) still
    # dominates when smaller (see startup validator in `_validate_options`).
    max_iterations_ceiling: int = 8
    # Stall threshold: N matching signatures in a row block the fix-loop with
    # blocker `stall_threshold exceeded`. Helper-call semantics: signature 1
    # → stall_count 0; signature 2 (matching) → stall_count 1; signature 3
    # (matching) → stall_count 2 → blocks at threshold 2.
    stall_threshold: int = 2
    # Disable progress detection (legacy behaviour). When True, signatures are
    # still computed but never counted as stalls.
    no_progress_detection: bool = False
    resume: bool = False
    on_handback: HandbackFn | None = None
    # Autonomous mode: when True, ``conduct()`` walks every unfinished phase in
    # a single Python process under one lock acquisition, only handing back on
    # a hard-stop (rogue commit, schema error, validation-cmd failure, stall,
    # iteration ceiling, max_phases cap). Default False preserves the legacy
    # one-phase-per-resume contract.
    autonomous: bool = False
    # Optional cap on total phases walked in autonomous mode. ``None`` is
    # resolved at ``conduct()`` entry to ``len(parsed_phases) + 1`` (the +1
    # leaves a single-iteration headroom; the cap fires before the (N+1)th
    # phase would enter ``_run_phase``). Resolution happens inline at
    # ``conduct()`` entry — NOT in ``__post_init__`` — because parsed phase
    # count is not known until after preflight + plan parsing.
    max_phases: int | None = None
    # Phase 3 ci-parity gate flags.
    #   run_ci_parity: enable the gate explicitly. Implied by autonomous=True.
    #   ci_cmd: override the detected CI entrypoint (e.g. "just ci", "make ci",
    #     or any user-supplied shell command).
    #   skip_ci_parity: short-circuit the gate to status="complete" with a skip
    #     summary; preserves any in-flight request / result files on disk.
    #   ci_parity_spawn: test-only synchronous dispatch seam. When set, the
    #     gate runs the spawner inline and consumes the resulting JSON in the
    #     same Python turn (no lock release). Production runs leave this None
    #     and rely on the main-runtime orchestrator + result-file handoff.
    run_ci_parity: bool = False
    ci_cmd: str | None = None
    skip_ci_parity: bool = False
    ci_parity_spawn: CIParitySpawnFn | None = None


@dataclass
class ConductResult:
    status: str  # 'awaiting_user' | 'blocked' | 'schema_error' | 'complete' | 'preflight_fail' | 'awaiting_ci_parity'
    state: dict
    summary: str
    next_command: str | None = None
    diagnostic: str | None = None
    # Phase 3 ci-parity gate handoff fields (reserved now; populated only when
    # status == 'awaiting_ci_parity'). Defined here so the runtime orchestrator
    # can read them directly off the result without round-tripping state.
    next_action: str | None = None  # e.g. 'dispatch_ci_parity'
    request: dict | None = None  # ci-parity request payload (see Phase 3 spec)


def _validate_options(opts: ConductOptions) -> None:
    """Startup validator. Emits one warning per misconfiguration.

    Currently only checks ``stall_threshold >= max_iterations`` while progress
    detection is enabled — under that configuration the legacy cap will always
    fire before the stall threshold can, so the stall configuration is
    effectively dead (and probably a typo).
    """
    if not opts.no_progress_detection and opts.stall_threshold >= opts.max_iterations:
        warnings.warn(
            f"conduct: stall_threshold={opts.stall_threshold} is "
            f">= max_iterations={opts.max_iterations}; legacy cap will "
            "always fire first (stall detection effectively disabled).",
            RuntimeWarning,
            stacklevel=2,
        )


def _check_iteration_bound(
    state: dict,
    opts: ConductOptions,
    signature: str,
) -> ConductResult | None:
    """Single source of truth for ``iteration_count += 1`` and the dual-cap +
    stall check across all three fix-loop call sites.

    Semantics (helper-owns-increment invariant):

    1. ``state["iteration_count"] += 1`` — only place in the module.
    2. Push ``signature`` onto ``state["stall_signatures"]``, truncate to
       length 2 (oldest first).
    3. If the new entry equals the previous entry, ``state["stall_count"] +=
       1``; else reset ``state["stall_count"] = 0``.
    4. Return blocked ``ConductResult("stall_threshold exceeded", ...)`` if
       ``state["stall_count"] >= opts.stall_threshold`` (unless progress
       detection is disabled).
    5. Return blocked ``ConductResult("max_iterations_ceiling exceeded", ...)``
       if ``state["iteration_count"] > opts.max_iterations_ceiling``.
    6. Return blocked ``ConductResult("max_iterations exceeded (legacy)",
       ...)`` if ``state["iteration_count"] > opts.max_iterations``.
    7. Otherwise return ``None``.

    Call ORDER at each site MUST be: observe the failure (compute the
    signature from ``failing_tests`` + ``compute_staged_diff_stat``), then
    invoke this helper. This preserves byte-identical iteration_count
    semantics with today's code, where the bump always fires AFTER the failure
    is observable.
    """
    state["iteration_count"] = state.get("iteration_count", 0) + 1

    history = list(state.get("stall_signatures") or [])
    prev_sig = history[-1] if history else None
    history.append(signature)
    # Rolling window of length 2, oldest first.
    if len(history) > 2:
        history = history[-2:]
    state["stall_signatures"] = history

    if prev_sig is not None and signature == prev_sig:
        state["stall_count"] = state.get("stall_count", 0) + 1
    else:
        state["stall_count"] = 0

    # Stall threshold fires first (it represents "no progress", which is a
    # stronger signal than "ran out of attempts"). Disabled when
    # `no_progress_detection` is set.
    if not opts.no_progress_detection and state["stall_count"] >= opts.stall_threshold:
        state["status"] = "blocked"
        state["blocker"] = "stall_threshold exceeded"
        return ConductResult(
            status="blocked",
            state=state,
            summary=state["blocker"],
        )

    if state["iteration_count"] > opts.max_iterations_ceiling:
        state["status"] = "blocked"
        state["blocker"] = "max_iterations_ceiling exceeded"
        return ConductResult(
            status="blocked",
            state=state,
            summary=state["blocker"],
        )

    if state["iteration_count"] > opts.max_iterations:
        state["status"] = "blocked"
        state["blocker"] = "max_iterations exceeded (legacy)"
        return ConductResult(
            status="blocked",
            state=state,
            summary=state["blocker"],
        )

    return None


def _extract_failing_tests_from_output(output: str) -> list[str]:
    """Best-effort pytest failing-test extractor for the stall signature.

    Looks for lines emitted by pytest's failure summary (``FAILED <nodeid>``).
    Returns the sorted, de-duplicated list of node ids found, or ``[]`` if no
    such lines are present. The diff stat then carries the signal alone — a
    stalled implementer typically produces both an unchanged failing set AND
    an unchanged diff, so signature collision is preserved either way.
    """
    if not output:
        return []
    found: set[str] = set()
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("FAILED "):
            # ``FAILED tests/x.py::test_y - AssertionError: ...``
            rest = stripped[len("FAILED ") :].strip()
            nodeid = rest.split(" ", 1)[0]
            if nodeid:
                found.add(nodeid)
    return sorted(found)


def _extract_failing_hook_ids(output: str) -> list[str]:
    """Best-effort pre-commit failing-hook-id extractor for the stall signature.

    pre-commit's per-hook summary lines look like ``ruff.....Failed`` or
    ``ruff-format.....Failed``. Captures the hook id before the dotted leader
    and returns sorted, de-duplicated ids. Returns ``[]`` if nothing parses —
    the diff stat then carries the signal alone.
    """
    if not output:
        return []
    found: set[str] = set()
    for line in output.splitlines():
        # pre-commit hook lines have the form '<hook-id>....Failed' (variable
        # dot count, with optional surrounding whitespace).
        stripped = line.strip()
        if "Failed" not in stripped or "." not in stripped:
            continue
        # Split on the first run of dots; the head is the hook id.
        head = stripped
        # Walk forward until we hit a '.'; everything to that point is the id.
        dot = head.find(".")
        if dot <= 0:
            continue
        candidate = head[:dot].strip()
        # Filter obvious non-ids (paths, file names with spaces).
        if not candidate or " " in candidate or "/" in candidate:
            continue
        # Skip anything that looks like a normal sentence (capitalised word
        # followed by lowercase prose) — hook ids are short kebab-case tokens.
        if len(candidate) > 64:
            continue
        # The tail must indicate failure.
        if "Failed" not in stripped[dot:]:
            continue
        found.add(candidate)
    return sorted(found)


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


def run_preflight(opts: ConductOptions) -> ConductResult | None:
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
        if opts.resume:
            # A phase legitimately amended the contract section above the
            # marker (workspace edits below the marker do not affect the hash
            # by construction, so a stale marker on resume always means an
            # above-marker edit). Rewrite the marker in place rather than
            # forcing the user to re-run /review-plan: the user has already
            # committed to this plan by starting the run, and an interrupted
            # phase is not a good moment to demand a fresh review pass. Initial
            # runs (no --resume) keep the hard-stop — refreshing there would
            # silently bless drift between /review-plan and the first phase.
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


def _safe_read_state_text(path: Path) -> str:
    """Open the main state file refusing to follow symlinks, capped at
    ``_MAX_LEGACY_STATE_BYTES``. Defence-in-depth against a symlink swapped in
    between the pre-lock ``_ensure_safe_fs_path`` check and the read: even
    though the state-lock window narrows the race, a TOCTOU swap inside it
    would otherwise let an attacker redirect the read to an arbitrary file.
    Raises ``RuntimeError`` on symlink/OS failure or size cap; the caller is
    expected to surface the error rather than fall through to ``json.loads``
    on bytes from an unrelated file."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(path), flags)
    except OSError as exc:
        raise RuntimeError(f"refusing to read state file at {path}: {exc}") from exc
    try:
        st = os.fstat(fd)
        if st.st_size > _MAX_LEGACY_STATE_BYTES:
            raise RuntimeError(
                f"state file at {path} exceeds {_MAX_LEGACY_STATE_BYTES}-byte cap"
            )
        return os.read(fd, _MAX_LEGACY_STATE_BYTES).decode("utf-8")
    finally:
        os.close(fd)


def _safe_read_legacy_state(path: Path) -> bytes | None:
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
    return (
        opts.repo_root
        / ".conduct"
        / f"state-{_RUNTIME_AUTHOR}-{opts.plan_path.stem}-{digest}.json"
    )


def _legacy_state_path(opts: ConductOptions) -> Path:
    """Pre-digest legacy path: `.conduct/state-<plan-stem>.json`."""
    return opts.repo_root / ".conduct" / f"state-{opts.plan_path.stem}.json"


def _pre_partition_state_path(opts: ConductOptions) -> Path:
    """Pre-runtime-partition legacy path: `.conduct/state-<plan-stem>-<digest>.json`.

    This was the active path before Phase 1 introduced runtime-author
    partitioning. The other runtime may still need to bootstrap from it, so
    callers MUST read non-destructively.
    """
    try:
        rel_plan = (
            opts.plan_path.resolve().relative_to(opts.repo_root.resolve()).as_posix()
        )
    except ValueError:
        rel_plan = opts.plan_path.resolve().as_posix()
    digest = hashlib.sha1(rel_plan.encode("utf-8")).hexdigest()[:12]
    return opts.repo_root / ".conduct" / f"state-{opts.plan_path.stem}-{digest}.json"


def _bootstrap_from_legacy_state(opts: ConductOptions) -> dict | None:
    """Non-destructively load a legacy state file as bootstrap input.

    Tries the pre-runtime-partition path first, then the pre-digest path.
    Returns the parsed state dict if a legacy file exists, parses, has a
    matching (or absent) `plan_path`, and a `state_author` matching this
    runtime (or absent). Returns None otherwise.

    The legacy file is NEVER renamed or deleted: the *other* runtime may
    still bootstrap from the same file. Each runtime persists its own
    runtime-specific state via `_persist_state` after bootstrap.
    """
    for legacy in (_pre_partition_state_path(opts), _legacy_state_path(opts)):
        if not legacy.exists() or legacy.is_symlink():
            continue
        raw = _safe_read_legacy_state(legacy)
        if raw is None:
            continue
        try:
            parsed = json.loads(raw.decode("utf-8", errors="strict"))
        except (UnicodeDecodeError, ValueError):
            continue
        if not isinstance(parsed, dict):
            continue
        recorded = parsed.get("plan_path")
        if recorded and Path(recorded).resolve() != opts.plan_path.resolve():
            continue
        author = parsed.get("state_author")
        if author is not None and author != _RUNTIME_AUTHOR:
            # The other runtime owns this legacy snapshot; do not consume.
            continue
        return parsed
    return None


def _migrate_legacy_state_file(opts: ConductOptions) -> None:
    """Bootstrap from a legacy state file into the runtime-specific path.

    Non-destructive: legacy files are read only; never renamed or deleted.
    The other runtime may still need to bootstrap from the same file. Each
    runtime stamps `state_author` on its first runtime-specific write.

    No-op if the runtime-specific state file already exists, no eligible
    legacy file is found, or the legacy `plan_path` / `state_author` do not
    match this runtime.
    """
    sp = _state_path(opts)
    if sp.exists():
        return
    parsed = _bootstrap_from_legacy_state(opts)
    if parsed is None:
        return
    parsed["state_author"] = _RUNTIME_AUTHOR
    try:
        _ensure_safe_conduct_dir(opts.repo_root)
        _ensure_safe_fs_path(sp, expect_dir=False)
        _safe_write_text(sp, json.dumps(parsed, indent=2))
    except (FileNotFoundError, FileExistsError, OSError, UnsafeConductPathError):
        # Concurrent bootstrap or symlink races: bail. The next load will
        # observe whichever file landed at sp.
        return


def _compute_cross_runtime_plan_id(plan_path: Path) -> str:
    """Derive a stable 12-char plan-id from the absolute plan path.

    Renamed from ``_compute_plan_id`` to disambiguate from ``_state_path``'s
    rel-path digest used for state-file naming.

    Matches the convention re-used by ``_state_path`` (which digests the
    repo-relative path); the spec calls for ``sha1(abs(plan_path))[:12]`` so
    callers — including a future autonomous main-Claude orchestrator — can
    re-derive the id without re-loading state. Different formula from the
    existing state-file digest is intentional: state-file naming is scoped to
    a repo-root, while plan_id is scoped to the absolute filesystem path so
    cross-worktree main-Claude flows agree on the id.
    """
    abs_path = plan_path.resolve().as_posix()
    return hashlib.sha1(abs_path.encode("utf-8")).hexdigest()[:12]


def _maybe_warn_unknown_schema_version(version: int) -> None:
    """Emit the unknown-≥1 schema_version forward-compat warning at most once
    per Python process. A fresh ``--resume`` invocation re-fires the warning
    because module-level state resets at process start.
    """
    global _UNKNOWN_SCHEMA_VERSION_WARNED
    if _UNKNOWN_SCHEMA_VERSION_WARNED:
        return
    _UNKNOWN_SCHEMA_VERSION_WARNED = True
    warnings.warn(
        f"state file written by newer schema_version={version}; "
        "reading known fields only",
        RuntimeWarning,
        stacklevel=2,
    )


def _apply_v1_defaults(state: dict, opts: ConductOptions) -> bool:
    """Populate v1 default values for fields the loader is responsible for.

    Returns True iff the state dict was mutated (caller persists on True).
    Centralises forward-compat defaults: even when reading an unknown
    ``schema_version`` >=1, the loader still backfills known-field defaults
    so the in-memory state object satisfies the documented v1 contract.
    """
    mutated = False
    if "stall_signatures" not in state:
        state["stall_signatures"] = []
        mutated = True
    if "stall_count" not in state:
        state["stall_count"] = 0
        mutated = True
    if "plan_id" not in state:
        state["plan_id"] = _compute_cross_runtime_plan_id(opts.plan_path)
        mutated = True
    if "state_author" not in state:
        state["state_author"] = _RUNTIME_AUTHOR
        mutated = True
    if "schema_version" not in state:
        # Absent is treated as 1 per the forward-compat rule.
        state["schema_version"] = 1
        mutated = True
    return mutated


def _load_or_init_state(opts: ConductOptions) -> dict:
    _migrate_legacy_state_file(opts)
    sp = _state_path(opts)
    if sp.exists():
        state = json.loads(_safe_read_state_text(sp))
        # Forward-compat hard-stop: a future schema may set
        # ``incompatible_with_pre_vN: true`` to signal that the file MUST NOT be
        # read by a loader older than vN. Honour it regardless of schema_version
        # so older readers reject the file cleanly rather than misreading it.
        incompat_marker = state.get("incompatible_with_pre_vN")
        if incompat_marker is True or (
            isinstance(incompat_marker, int) and incompat_marker > 0
        ):
            raise RuntimeError(
                "state file requires a newer conduct loader "
                f"(incompatible_with_pre_vN={incompat_marker!r}); "
                "upgrade /conduct or remove the state file to start fresh"
            )
        # Forward-compat: handle unknown schema_version BEFORE backfill so the
        # warning fires against the raw on-disk value. Known set right now is
        # {absent, 1, 2}; Phase 1 writes 1, Phase 3 will write 2.
        sv = state.get("schema_version")
        if sv is not None and isinstance(sv, int) and sv >= 1 and sv not in (1, 2):
            _maybe_warn_unknown_schema_version(sv)
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
        if _apply_v1_defaults(state, opts):
            mutated = True
        if opts.resume:
            state["resume_base_sha"] = _head_sha(opts.repo_root)
            # Preserve terminal / awaiting statuses so the resume entry points
            # (awaiting_ci_parity preflight, legacy post-consume early-return,
            # ci_failed handback) can observe them. Only transition to
            # "running" if the prior status was a mid-run / fresh-dispatch
            # value.
            if state.get("status") not in {
                "awaiting_ci_parity",
                "complete",
                "ci_failed",
            }:
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
        "stall_signatures": [],
        "stall_count": 0,
        "plan_id": _compute_cross_runtime_plan_id(opts.plan_path),
        "state_author": _RUNTIME_AUTHOR,
        "schema_version": 1,
    }
    _persist_state(opts, state)
    return state


def _persist_state(opts: ConductOptions, state: dict) -> None:
    # Phase 3: bump on-disk ``schema_version`` to 2 once any of the
    # ci_parity_* fields are present in the in-memory state. Phases 1-2 keep
    # writing 1; the loader treats unknown ≥1 with a one-shot warning so older
    # readers still degrade gracefully.
    if any(field in state for field in _PHASE_3_STATE_FIELDS):
        state["schema_version"] = _STATE_SCHEMA_VERSION
    sp = _state_path(opts)
    _ensure_safe_conduct_dir(opts.repo_root)
    _safe_write_text(sp, json.dumps(state, indent=2))


# ---------------------------------------------------------------------------
# CI-parity result file (Phase 3)
# ---------------------------------------------------------------------------


def _write_ci_parity_result(path: Path, payload_text: str) -> None:
    """Conductor-owned adapter for ci-parity result persistence.

    Validates that ``path`` resolves underneath the repo's ``.conduct/``
    directory (defence-in-depth against a ``plan_id`` containing ``..``
    segments — see ``fileutil.ensure_under_directory``), ensures the parent
    exists, and delegates to ``fileutil.atomic_write_result_file``.
    Production orchestrators and tests both flow through this adapter so
    the atomic-write contract is a single invariant rather than a
    per-call-site convention.
    """
    parent = path.parent
    if not parent.exists():
        parent.mkdir(parents=True, exist_ok=True)
    # Resolved-path containment supersedes the previous ``parents``-name
    # check, which accepted ``.conduct/foo/../../escape.json``.
    try:
        ensure_under_directory(path, parent.parent)
    except ValueError as e:
        raise UnsafeConductPathError(str(e)) from e
    # Sanity: the immediate parent must itself be a ``.conduct`` directory,
    # because that is the only place preflight knows to look. The resolved
    # check above guarantees we have not escaped via ``..``; this check
    # guards against being passed a path inside a *different* ``.conduct``
    # parent (e.g. someone constructs an absolute path manually).
    if parent.name != ".conduct":
        raise UnsafeConductPathError(
            f"ci-parity result path must live directly under .conduct/: {path}"
        )
    _ensure_safe_fs_path(parent, expect_dir=True)
    _ensure_safe_fs_path(path, expect_dir=False)
    _atomic_write_result_file(path, payload_text)


def _ci_parity_result_path(opts: ConductOptions, plan_id: str) -> Path:
    # ``plan_id`` flows from on-disk state, so validate the shape before
    # interpolating it into a filesystem path. A malformed ``plan_id`` is
    # an upstream-state bug; raising here surfaces it at the first read or
    # write attempt rather than letting traversal silently succeed.
    validate_plan_id(plan_id)
    return opts.repo_root / ".conduct" / f"ci-parity-result-{plan_id}.json"


def _ci_parity_consumed_pattern(repo_root: Path, plan_id: str) -> list[Path]:
    """Return matching ``.consumed-<unix>.json`` files for this plan_id.

    ``plan_id`` is validated before being interpolated into the glob pattern
    so a malformed value cannot expand into a traversal pattern.
    """
    validate_plan_id(plan_id)
    conduct_dir = repo_root / ".conduct"
    if not conduct_dir.exists() or not conduct_dir.is_dir():
        return []
    prefix = f"ci-parity-result-{plan_id}.consumed-"
    return sorted(conduct_dir.glob(f"{prefix}*.json"))


def _consume_ci_parity_result(
    opts: ConductOptions,
    state: dict,
    ci_parity_report: dict,
) -> ConductResult:
    """Apply a parsed ci-parity report to state. Shared by test and prod paths.

    Test-injection path: called synchronously after ``opts.ci_parity_spawn``
    returns the worker JSON.
    Production path: called by preflight after reading the result file.

    Both paths produce byte-identical state mutations — this is the invariant
    behind ``ci-parity-injection-and-result-file-paths-share-consume-code``.
    """
    state["ci_parity_result"] = ci_parity_report
    state["ci_parity_dispatched"] = True
    # Counter resets on any non-absent outcome including consume.
    state["ci_parity_missing_resume_count"] = 0

    status = ci_parity_report.get("status")
    if status == "passed":
        state["status"] = "complete"
        state["blocker"] = None
        summary_text = ci_parity_report.get("summary") or "ci-parity passed"
        state["last_summary"] = f"ci-parity: {summary_text}"
        _persist_state(opts, state)
        return ConductResult(
            status="complete",
            state=state,
            summary=f"All phases complete; ci-parity passed: {summary_text}",
        )
    # ``failed`` (or any other non-passed terminal status from the worker).
    state["status"] = "ci_failed"
    blocker = (
        f"ci-parity failed: {ci_parity_report.get('summary') or 'see ci_parity_result'}"
    )
    state["blocker"] = blocker
    summary_text = ci_parity_report.get("summary") or "ci-parity failed"
    state["last_summary"] = f"ci-parity: {summary_text}"
    _persist_state(opts, state)
    next_cmd = f"Run: /conduct --resume {opts.plan_path}"
    result = ConductResult(
        status="ci_failed",
        state=state,
        summary=blocker,
        next_command=next_cmd,
        diagnostic=(ci_parity_report.get("last_2000_bytes_of_output") or "")[-2000:],
    )
    if opts.on_handback:
        opts.on_handback(state)
    return result


def _ci_parity_request_validation_error(request: dict, report: dict) -> str | None:
    plan_id = request.get("plan_id")
    try:
        validate_plan_id(plan_id)
    except ValueError as exc:
        return str(exc)
    if report.get("plan_id") != plan_id:
        return "plan_id mismatch"
    request_written_at = request.get("request_written_at_unix")
    report_written_at = report.get("request_written_at_unix")
    if request_written_at is None or report_written_at is None:
        return "request_written_at_unix missing"
    try:
        if float(report_written_at) != float(request_written_at):
            return "request_written_at_unix mismatch"
    except (TypeError, ValueError):
        return "request_written_at_unix invalid"
    requested_cmd = request.get("ci_cmd")
    if requested_cmd is not None and report.get("command_run") != requested_cmd:
        return "command_run mismatch"
    return None


def _state_path_matches_plan(state: dict, opts: ConductOptions) -> bool:
    plan_path = state.get("plan_path")
    if not isinstance(plan_path, str):
        return False
    return Path(plan_path).resolve() == opts.plan_path.resolve()


def _completed_phase_prefix_error(state: dict, phases: list[Phase]) -> str | None:
    completed = state.get("completed_phases") or []
    if len(completed) > len(phases):
        return (
            f"completed phase count {len(completed)} exceeds parsed phase count "
            f"{len(phases)}"
        )
    for idx, entry in enumerate(completed):
        if not isinstance(entry, dict):
            return f"completed phase entry {idx + 1} is not an object"
        expected = phases[idx]
        if entry.get("label") != expected.label or entry.get("title") != expected.title:
            return (
                "completed phase prefix no longer matches reviewed plan at "
                f"position {idx + 1}: state has Phase {entry.get('label')}: "
                f"{entry.get('title')}; plan has Phase {expected.label}: "
                f"{expected.title}"
            )
    return None


def _phase_prefix_mismatch_result(
    opts: ConductOptions, state: dict, detail: str
) -> ConductResult:
    state["status"] = "blocked"
    state["blocker"] = "completed phase prefix no longer matches reviewed plan"
    _persist_state(opts, state)
    return ConductResult(
        status="blocked",
        state=state,
        summary=state["blocker"],
        diagnostic=(
            f"{detail}\n"
            "A reviewed structural edit changed phases that were already marked "
            "complete. Run /conduct --abort-run and restart, or restore the "
            "completed phase prefix before resuming."
        ),
    )


def _move_result_to_consumed(result_path: Path) -> None:
    """Move ``ci-parity-result-<plan-id>.json`` to ``.consumed-<unix>.json``.

    Best-effort: on any OS error we leave the active file in place. Preflight
    on the next ``--resume`` will treat the file as present-and-valid again,
    which is idempotent because the consume code resets state to ``complete``.
    """
    try:
        consumed = result_path.with_name(
            result_path.stem + f".consumed-{int(time.time())}.json"
        )
        os.replace(str(result_path), str(consumed))
    except OSError:
        pass


def _dispatch_ci_parity_if_eligible(
    opts: ConductOptions,
    state: dict,
    phases_len: int,
) -> ConductResult:
    """End-of-plan ci-parity gate. Returns a ConductResult describing outcome.

    Called from both lifecycle points:
      - autonomous phase loop exit (after the ``while True:`` breaks),
      - legacy non-autonomous: top of ``conduct()`` when all phases are
        complete AND the gate has not yet dispatched, before the "All phases
        complete" early return.

    Logic (see SKILL.md "CI Parity Gate" section):
      * ``--skip-ci-parity`` → status ``complete`` with skip summary.
      * Else (autonomous OR ``--run-ci-parity``): detect entrypoint OR use
        ``opts.ci_cmd``. If a ``ci_parity_spawn`` is injected, run the gate
        synchronously and consume the result inline (no lock release). Else
        (production) write the request to state, set
        ``status=awaiting_ci_parity``, and return a result the main runtime
        orchestrator dispatches against.
      * No entrypoint AND no override → blocked; user must pass ``--ci-cmd``
        or ``--skip-ci-parity``.
    """
    retrying_ci_failed = state.get("status") == "ci_failed"
    if opts.skip_ci_parity:
        state["ci_parity_dispatched"] = True
        state["status"] = "complete"
        state["last_summary"] = "ci-parity: skipped (--skip-ci-parity)"
        state["blocker"] = None
        _persist_state(opts, state)
        return ConductResult(
            status="complete",
            state=state,
            summary="All phases complete; ci-parity skipped (--skip-ci-parity)",
        )

    if not (opts.autonomous or opts.run_ci_parity or retrying_ci_failed):
        # Gate not requested. Plain complete (legacy default).
        state["status"] = "complete"
        _persist_state(opts, state)
        return ConductResult(
            status="complete", state=state, summary="All phases complete"
        )

    # Resolve entrypoint: explicit override beats detection.
    if opts.ci_cmd:
        kind = "override"
        cmd = opts.ci_cmd
    else:
        detected = detect_ci_entrypoint(opts.repo_root)
        if detected is None:
            state["status"] = "blocked"
            state["blocker"] = (
                "ci-parity entrypoint not detected; pass --ci-cmd or --skip-ci-parity"
            )
            state["last_summary"] = state["blocker"]
            _persist_state(opts, state)
            return ConductResult(
                status="blocked",
                state=state,
                summary=state["blocker"],
                diagnostic=(
                    "No CI entrypoint detected (just/make/npm/cargo). "
                    "Pass --ci-cmd to run a command or --skip-ci-parity to abandon the gate."
                ),
            )
        kind, cmd = detected

    if retrying_ci_failed:
        state.pop("ci_parity_request", None)
        state["ci_parity_result"] = None
        state["ci_parity_dispatched"] = False
        state["ci_parity_missing_resume_count"] = 0
        state["blocker"] = None

    plan_id = state.get("plan_id") or _compute_cross_runtime_plan_id(opts.plan_path)

    # In-flight request idempotency: if state already carries a request, reuse
    # its ``request_written_at_unix`` rather than refreshing it. This is what
    # makes ``--ci-cmd`` overrides on a re-resume non-mutating (the live
    # request was already persisted at dispatch time).
    existing_request = state.get("ci_parity_request")
    if existing_request:
        request = dict(existing_request)
        written_at = state.get("ci_parity_request_written_at") or existing_request.get(
            "request_written_at_unix"
        )
    else:
        written_at = time.time()
        head_sha = _head_sha(opts.repo_root)
        request = {
            "plan_path": str(opts.plan_path),
            "base_sha": state.get("base_sha", ""),
            "head_sha": head_sha,
            "ci_entrypoint_kind": kind,
            "ci_cmd": cmd,
            "repo_root": str(opts.repo_root),
            "plan_id": plan_id,
            "request_written_at_unix": written_at,
        }
        state["ci_parity_request"] = request
        state["ci_parity_request_written_at"] = written_at
        state.setdefault("ci_parity_missing_resume_count", 0)

    # Test-injection seam: synchronous spawner, consume inline. No lock release
    # because we never leave this Python turn.
    if opts.ci_parity_spawn is not None:
        spawn_req = CIParitySpawnRequest(
            plan_path=request["plan_path"],
            base_sha=request["base_sha"],
            head_sha=request["head_sha"],
            ci_entrypoint_kind=request["ci_entrypoint_kind"],
            ci_cmd=request["ci_cmd"],
            repo_root=request["repo_root"],
            plan_id=request["plan_id"],
            request_written_at_unix=request["request_written_at_unix"],
        )
        text = opts.ci_parity_spawn(spawn_req)
        try:
            report = parse_report(text, "ci-parity")
        except SchemaError as exc:
            state["status"] = "schema_error"
            state["blocker"] = f"ci-parity worker schema error: {exc}"
            _persist_state(opts, state)
            return ConductResult(
                status="schema_error",
                state=state,
                summary=state["blocker"],
                diagnostic=str(exc),
            )
        validation_error = _ci_parity_request_validation_error(request, report)
        if validation_error is not None:
            state["status"] = "schema_error"
            state["blocker"] = (
                f"ci-parity worker report did not match request: {validation_error}"
            )
            _persist_state(opts, state)
            return ConductResult(
                status="schema_error",
                state=state,
                summary=state["blocker"],
                diagnostic=validation_error,
            )
        return _consume_ci_parity_result(opts, state, report)

    # Production: main-runtime orchestrates the worker. Persist state and
    # return ``awaiting_ci_parity`` so ``conduct()`` releases the lock by
    # falling out of ``with lock:``.
    state["status"] = "awaiting_ci_parity"
    _ensure_safe_conduct_dir(opts.repo_root)
    _persist_state(opts, state)
    return ConductResult(
        status="awaiting_ci_parity",
        state=state,
        summary="awaiting ci-parity result",
        next_action="dispatch_ci_parity",
        request=request,
    )


def _preflight_ci_parity_resume(
    opts: ConductOptions,
    state: dict,
) -> ConductResult | None:
    """Handle ``awaiting_ci_parity`` state at re-invocation.

    Returns a ConductResult when one of the five sub-cases fires; returns None
    when the conductor should continue normal flow (only happens on consume +
    successful state transition, which already returns a ConductResult — so
    in practice this helper always returns a ConductResult when state is in
    ``awaiting_ci_parity``).

    Five sub-cases (see plan Phase 3):
      1. Present + valid + matches state → consume, move file to .consumed.
      2. Present but stale (mtime older OR plan_id mismatch OR
         request_written_at_unix mismatch) → re-emit awaiting_ci_parity;
         reset missing-counter.
      3. Present but malformed (json/schema fail) → schema_error, preserve.
      4. Absent active file BUT matching .consumed-<unix>.json with matching
         request_written_at_unix → TOCTOU recovery: consume via the
         consumed-file payload, skip the move.
      5. Absent (no consumed match) → increment counter; ≥3 → handback.
    """
    request = state.get("ci_parity_request") or {}
    plan_id = (
        request.get("plan_id")
        or state.get("plan_id")
        or _compute_cross_runtime_plan_id(opts.plan_path)
    )
    # Non-resume invocation against awaiting_ci_parity state: hard-fail per
    # the lock-release-contention contract.
    if not opts.resume and not opts.skip_ci_parity:
        return ConductResult(
            status="blocked",
            state=state,
            summary=(
                "state shows awaiting_ci_parity; use --resume to consume the "
                "ci-parity result or --skip-ci-parity to abandon the gate"
            ),
            diagnostic=(
                "state shows awaiting_ci_parity; use --resume to consume or "
                "--skip-ci-parity to abandon"
            ),
        )

    # ``--skip-ci-parity`` from awaiting state: short-circuit to complete and
    # leave the request + any on-disk result file untouched (artifact preserve
    # invariant — `ci-parity-skip-ci-parity-during-awaiting-preserves-artifacts`).
    if opts.skip_ci_parity:
        state["ci_parity_dispatched"] = True
        state["status"] = "complete"
        state["last_summary"] = (
            "ci-parity: skipped from awaiting_ci_parity (--skip-ci-parity)"
        )
        state["blocker"] = None
        _persist_state(opts, state)
        return ConductResult(
            status="complete",
            state=state,
            summary="ci-parity skipped from awaiting_ci_parity (--skip-ci-parity)",
        )

    result_path = _ci_parity_result_path(opts, plan_id)

    try:
        raw, _result_mtime = read_result_file(result_path)
    except FileNotFoundError:
        raw = None
    except (OSError, UnicodeDecodeError) as exc:
        state["ci_parity_missing_resume_count"] = 0
        state["status"] = "schema_error"
        state["blocker"] = f"ci-parity result file unreadable at {result_path}: {exc}"
        _persist_state(opts, state)
        return ConductResult(
            status="schema_error",
            state=state,
            summary=state["blocker"],
            diagnostic=str(exc),
        )

    if raw is not None:
        # Sub-case 1, 2, or 3.
        try:
            report = parse_report(raw, "ci-parity")
        except SchemaError as exc:
            # Sub-case 3: malformed — preserve the file for inspection.
            state["status"] = "schema_error"
            state["blocker"] = (
                f"ci-parity result file malformed at {result_path}: {exc}"
            )
            _persist_state(opts, state)
            return ConductResult(
                status="schema_error",
                state=state,
                summary=state["blocker"],
                diagnostic=str(exc),
            )
        # Stale checks. Any non-absent outcome resets the missing counter.
        # Staleness is decided by request-binding fields
        # (``plan_id`` / ``request_written_at_unix`` / ``command_run`` echoed
        # in the report) via ``_ci_parity_request_validation_error``. The
        # filesystem mtime is intentionally NOT consulted: coarse-mtime
        # filesystems (HFS+, some NFS) round to whole seconds and a worker
        # that finishes within the same second as the request emission can
        # produce an mtime that compares equal-or-less, flagging a valid
        # result as stale. Field-equality is the only correct discriminator.
        stale = _ci_parity_request_validation_error(request, report) is not None
        if stale:
            # Sub-case 2: ignore, re-emit awaiting_ci_parity.
            state["ci_parity_missing_resume_count"] = 0
            _persist_state(opts, state)
            return ConductResult(
                status="awaiting_ci_parity",
                state=state,
                summary="awaiting ci-parity result (stale file ignored)",
                next_action="dispatch_ci_parity",
                request=request,
            )
        # Sub-case 1: consume.
        outcome = _consume_ci_parity_result(opts, state, report)
        _move_result_to_consumed(result_path)
        return outcome

    # File absent. Check for sub-case 4 (TOCTOU recovery) before incrementing.
    consumed_candidates = _ci_parity_consumed_pattern(opts.repo_root, plan_id)
    for cand in consumed_candidates:
        try:
            raw, _mtime = read_result_file(cand)
            report = parse_report(raw, "ci-parity")
        except (OSError, UnicodeDecodeError, SchemaError):
            continue
        if _ci_parity_request_validation_error(request, report) is None:
            # TOCTOU recovery: another process consumed the file already.
            # Apply the canonical consume path, skip the move (already moved).
            return _consume_ci_parity_result(opts, state, report)

    # Sub-case 5: truly absent. Increment counter and re-emit (or handback).
    state["ci_parity_missing_resume_count"] = (
        state.get("ci_parity_missing_resume_count", 0) + 1
    )
    if state["ci_parity_missing_resume_count"] >= 3:
        state["status"] = "blocked"
        blocker = (
            "ci-parity result file missing after 3 resume attempts; "
            "pass --skip-ci-parity to abandon gate"
        )
        state["blocker"] = blocker
        _persist_state(opts, state)
        next_cmd = f"Run: /conduct --resume --skip-ci-parity {opts.plan_path}"
        result = ConductResult(
            status="blocked",
            state=state,
            summary=blocker,
            next_command=next_cmd,
        )
        if opts.on_handback:
            opts.on_handback(state)
        return result
    _persist_state(opts, state)
    return ConductResult(
        status="awaiting_ci_parity",
        state=state,
        summary="awaiting ci-parity result (file absent)",
        next_action="dispatch_ci_parity",
        request=request,
    )


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


def _resolve_test_cmd(opts: ConductOptions, phase: Phase) -> str | None:
    if opts.test_cmd_override:
        return opts.test_cmd_override
    if phase.test_command:
        return phase.test_command
    return _repo_default_test_cmd(opts.repo_root)


def detect_lint_command(repo_root: Path) -> list[str] | None:
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
            # Column-zero check only — matches the `_makefile_has_ci` convention
            # so `lint:` tokens inside recipe bodies or define/endef blocks are
            # not mistaken for a real target.
            if line.startswith(("lint:", "lint :")):
                return ["make", "lint"]

    pkg = repo_root / "package.json"
    if pkg.exists() and shutil.which("npm"):
        try:
            text = pkg.read_text()
        except OSError:
            text = ""
        if '"scripts"' in text and '"lint"' in text:
            return ["npm", "run", "lint"]

    if shutil.which("ruff") and (
        (repo_root / "pyproject.toml").exists() or any(repo_root.glob("*.py"))
    ):
        return ["ruff", "check", "."]

    return None


def default_lint_check(repo_root: Path) -> str | None:
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


def _repo_default_test_cmd(repo_root: Path) -> str | None:
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
            # Column-zero only; see `detect_lint_command` for the rationale.
            if line.startswith(("test:", "test :")):
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
    autonomous: bool = False,
) -> ConductResult:
    # Phase-start reset is guarded on entering a NEW phase (different title
    # from the one persisted in state). Without this guard, --resume mid-phase
    # would clobber the persisted iteration_count / stall_signatures and let
    # the fix-loop bound re-start at zero.
    if state.get("current_phase_title") != phase.title:
        state["iteration_count"] = 0
        state["stall_signatures"] = []
        state["stall_count"] = 0
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
        impl_text: str | None = None
        test_text: str | None = None

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
            if autonomous:
                # Autonomous mode: caller continues the phase loop without
                # handback. ``_commit_phase`` already appended to
                # ``state["completed_phases"]`` and persisted; return the
                # running result unchanged.
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
            if autonomous:
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

        # Step 6: fix loop. Signature is observed BEFORE the helper bumps the
        # counter — same ordering as today's pre-refactor code, where the
        # increment fired after the failure was visible to the conductor.
        failing_tests = _extract_failing_tests_from_output(result.output)
        signature = iteration_signature(
            failing_tests, compute_staged_diff_stat(opts.repo_root)
        )
        bound = _check_iteration_bound(state, opts, signature)
        _persist_state(opts, state)
        if bound is not None:
            bound.diagnostic = result.output[-2000:]
            return bound

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

    # Step 8.3 boundary commit. The Conducted-By trailer is appended to the
    # message body (blank-line-separated) so downstream tooling can identify
    # which conductor runtime (claude vs codex) produced the commit. We embed
    # the trailer directly in the message text rather than using ``git
    # commit --trailer`` because older git versions lack that flag.
    commit_subject = f"conduct: phase {phase.label} — {phase.title}"
    commit_msg = f"{commit_subject}\n\nConducted-By: claude"
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
        # Pre-commit hook failure → route into fix loop. The hook output is
        # the failure signal here; extract the failing hook ids (e.g. ruff,
        # ruff-format) so a stuck formatter loop is recognised as a stall.
        hook_output = proc.stdout + proc.stderr
        failing_hook_ids = _extract_failing_hook_ids(hook_output)
        signature = iteration_signature(
            failing_hook_ids, compute_staged_diff_stat(opts.repo_root)
        )
        bound = _check_iteration_bound(state, opts, signature)
        _persist_state(opts, state)
        if bound is not None:
            bound.diagnostic = hook_output[-2000:]
            return bound
        # Signal the caller to re-enter the loop. We do this by returning a
        # special marker the caller checks. But simpler: raise a sentinel.
        raise _CommitHookFailure(output=hook_output)

    completed = {
        "index": phase.position,
        "label": phase.label,
        "title": phase.title,
        "commit_sha": _head_sha(opts.repo_root),
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
    _validate_options(opts)
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
        all_phases = parse_phases(plan_text)

        if opts.resume:
            if not _state_path_matches_plan(state, opts):
                return ConductResult(
                    status="blocked",
                    state=state,
                    summary="conduct state belongs to a different plan",
                    diagnostic=(
                        f"Stored plan_path: {state.get('plan_path')}\n"
                        f"Current plan_path: {opts.plan_path}"
                    ),
                )
            prefix_error = _completed_phase_prefix_error(state, all_phases)
            if prefix_error is not None:
                return _phase_prefix_mismatch_result(opts, state, prefix_error)
            current_hash = compute_plan_hash(opts.plan_path)
            if state.get("plan_content_hash") != current_hash:
                state["plan_content_hash"] = current_hash
                _persist_state(opts, state)

        # Phase 3 awaiting_ci_parity preflight branch. Fires BEFORE phase
        # parsing because the gate is plan-complete by construction.
        if state.get("status") == "awaiting_ci_parity":
            return _preflight_ci_parity_resume(opts, state)

        phases = [p for p in all_phases if not p.is_complete]

        # Legacy non-autonomous ci-parity dispatch: if all phases are already
        # complete from a prior run AND the gate has not yet fired, dispatch
        # it now (before the "All phases complete" early return below).
        if (
            len(state.get("completed_phases", [])) >= len(phases)
            and len(phases) >= 0
            and not state.get("ci_parity_dispatched")
            and (
                opts.autonomous
                or opts.run_ci_parity
                or opts.skip_ci_parity
                or state.get("status") == "ci_failed"
            )
        ):
            return _dispatch_ci_parity_if_eligible(opts, state, len(phases))

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

        # Resolve max_phases inline at entry: parsed phase count is not known
        # in ``ConductOptions.__post_init__``. ``None`` → ``len(phases) + 1``
        # so a default-config run never trips the cap; explicit caps fire
        # when ``len(state["completed_phases"]) >= cap`` (post-commit count).
        max_phases_cap = (
            opts.max_phases if opts.max_phases is not None else len(phases) + 1
        )

        # Explicit phase loop. In legacy (non-autonomous) mode the loop runs
        # at most one full body iteration before ``_run_phase`` returns a
        # handback (status != "running") and we exit. In autonomous mode the
        # loop walks every unfinished phase under the single ``with lock:``
        # acquisition above — SKILL.md Step 9a documents this single-lock
        # property.
        while True:
            completed_count = len(state.get("completed_phases", []))
            if completed_count >= max_phases_cap:
                # Max-phases cap hit (hard-stop, autonomous-or-not). No phase
                # context yet for this iteration, so return a blocked result
                # directly rather than routing through ``_handback``.
                state["status"] = "blocked"
                state["blocker"] = f"max_phases ceiling hit ({max_phases_cap})"
                _persist_state(opts, state)
                return ConductResult(
                    status="blocked",
                    state=state,
                    summary=state["blocker"],
                )
            if completed_count >= len(phases):
                # All phases done; fall through to ci-parity gate.
                break
            phase = phases[completed_count]
            try:
                result = _run_phase(opts, state, phase, autonomous=opts.autonomous)
            except _CommitHookFailure as hook_fail:
                result = _retry_after_hook_failure(
                    opts, state, phase, hook_fail.output, autonomous=opts.autonomous
                )
            # Hard-stop or handback: return immediately.
            if result.status != "running":
                return result
            # Phase commit succeeded. Legacy (non-autonomous) mode: ``_run_phase``
            # already called ``_handback`` on the success path, so we never
            # observe ``running`` here. Autonomous mode: persist progress
            # (already done inside ``_commit_phase``) and continue the loop.
            if not opts.autonomous:
                # Defensive: a future refactor that changes ``_run_phase``'s
                # legacy return value would otherwise silently keep walking
                # phases under the single lock. Synthesise a handback so the
                # contract holds even if the assumption above is violated.
                return _handback(
                    opts,
                    state,
                    phase,
                    "passed",
                    state.get("iteration_count", 0),
                    "sequential",
                    "legacy-loop-fallback",
                    [],
                )

        # End-of-plan ci-parity gate. The helper handles all four paths:
        # skip, gate-not-requested → plain complete, test-injection consume,
        # production await. Idempotency: ``ci_parity_dispatched`` guards a
        # second invocation from re-dispatching (covered by
        # ``ci-parity-legacy-post-consume-resume-no-redispatch``).
        if state.get("ci_parity_dispatched") and state.get("status") == "complete":
            return ConductResult(
                status="complete",
                state=state,
                summary="All phases complete (ci-parity already consumed)",
            )
        return _dispatch_ci_parity_if_eligible(opts, state, len(phases))


def _retry_after_hook_failure(
    opts: ConductOptions,
    state: dict,
    phase: Phase,
    hook_output: str,
    autonomous: bool = False,
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
                failing_tests = _extract_failing_tests_from_output(result.output)
                signature = iteration_signature(
                    failing_tests, compute_staged_diff_stat(opts.repo_root)
                )
                bound = _check_iteration_bound(state, opts, signature)
                _persist_state(opts, state)
                if bound is not None:
                    bound.diagnostic = result.output[-2000:]
                    return bound
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
        if autonomous:
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
        state = json.loads(_safe_read_state_text(sp))
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
        except (OSError, RuntimeError):
            # StateLock.acquire/release raise only OSError or LockError
            # (a RuntimeError subclass); sp.unlink() raises only OSError.
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
