"""Review-marker helpers for the conduct skill.

The review marker is a single comment line:

    <!-- reviewed: YYYY-MM-DD @ <sha1> -->

The marker acts as a divider between the **immutable contract** above it and
the **workspace** below it (``## Progress``, ``## Findings``, etc.). The hash
is ``git hash-object`` of the plan content above the marker line — anything
on the marker line or below is excluded from hashing. This means the user (or
the conductor) can tick progress checkboxes or append findings after
``/review-plan`` without invalidating the marker.

Locating the marker: the final marker-shaped line in the file wins. Marker-
shaped text in prose or code fences earlier in the plan is ignored. If no
marker line exists, the plan is hashed as-is.

Note on crypto: the hash is SHA-1 (via ``git hash-object``). This is a
drift-detection stop-sign for plan edits, not a cryptographic authentication
of the plan body — an adversary who can edit the plan can also rewrite the
marker. Collision resistance is not part of the threat model.
"""

from __future__ import annotations

import re
import subprocess
from datetime import date
from pathlib import Path

MARKER_RE = re.compile(
    r"^<!-- reviewed: (\d{4}-\d{2}-\d{2}) @ ([0-9a-f]{40}) -->\s*$"
)
MARKER_PLACEHOLDER_RE = re.compile(r"^<!-- reviewed: YYYY-MM-DD @ <hash> -->\s*$")

FENCE_RE = re.compile(r"^\s*(```|~~~)")


def last_marker_index(
    lines: list[str], *, include_placeholder: bool = False
) -> int | None:
    """Return the index of the last marker line that is **not** inside a fenced
    code block, or ``None`` if no such line exists.

    ``include_placeholder`` lets `/review-plan` replace the template divider
    without treating it as a valid review marker during preflight.

    Public so ``parser.py`` (and other plan-walking code) can locate the
    contract/workspace boundary without re-implementing fence tracking.
    """
    in_fence = False
    last = None
    for i, line in enumerate(lines):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if MARKER_RE.match(line) or (
            include_placeholder and MARKER_PLACEHOLDER_RE.match(line)
        ):
            last = i
    return last


def strip_marker_for_hashing(plan_text: str) -> str:
    """Return the plan content above the marker line, ready for hashing.

    The marker line itself and **everything after it** are excluded — the
    workspace section (``## Progress``, ``## Findings``, etc.) lives below the
    marker and must not affect the hash. If no marker line is found, the plan
    is returned unchanged.

    Locating the marker: scan from the end and pick the last line that matches
    the marker regex (so a plan documenting marker syntax in prose earlier in
    the file is unaffected).
    """
    if not plan_text:
        return plan_text
    has_trailing_newline = plan_text.endswith("\n")
    lines = plan_text.splitlines()
    marker_idx = last_marker_index(lines, include_placeholder=True)
    if marker_idx is None:
        return plan_text
    remaining = lines[:marker_idx]
    while remaining and not remaining[-1].strip():
        remaining.pop()
    result = "\n".join(remaining)
    if remaining and has_trailing_newline:
        result += "\n"
    return result


def _hash_stripped(plan_text: str) -> str:
    """Pipe the stripped plan text to ``git hash-object --stdin``."""
    proc = subprocess.run(
        ["git", "hash-object", "--stdin"],
        input=plan_text.encode("utf-8"),
        capture_output=True,
        check=True,
    )
    return proc.stdout.decode("utf-8").strip()


def compute_plan_hash(plan_path: str | Path) -> str:
    """Return ``git hash-object`` of the plan with marker stripped per the rule
    above. Streams via stdin — no temp file is created on disk.
    """
    plan = Path(plan_path).read_text(encoding="utf-8")
    return _hash_stripped(strip_marker_for_hashing(plan))


def read_marker(plan_path: str | Path) -> tuple[str, str] | None:
    """Return ``(iso_date, sha1)`` for the last marker-shaped line in the plan,
    or ``None`` if no marker line is found. Workspace content (``## Progress``
    etc.) below the marker is ignored.
    """
    lines = Path(plan_path).read_text(encoding="utf-8").splitlines()
    idx = last_marker_index(lines)
    if idx is None:
        return None
    match = MARKER_RE.match(lines[idx])
    return match.group(1), match.group(2)


def write_marker(plan_path: str | Path, when: date | None = None) -> str:
    """Append or replace the marker line. Returns the new sha1.

    The marker is written immediately after the immutable contract (everything
    above any pre-existing marker, or the whole plan if none). Workspace
    content below an existing marker is preserved verbatim.

    Idempotent: running this repeatedly on an unchanged plan yields the same
    marker hash, possibly with a newer date.
    """
    path = Path(plan_path)
    plan = path.read_text(encoding="utf-8")
    above, below = _split_around_marker(plan)
    sha = _hash_stripped(above)

    iso = (when or date.today()).isoformat()
    marker_line = f"<!-- reviewed: {iso} @ {sha} -->"

    above_text = above
    if above_text and not above_text.endswith("\n"):
        above_text += "\n"

    if below:
        # Preserve the workspace below the marker; ensure exactly one blank
        # line separates the marker from the workspace heading.
        below_stripped = below.lstrip("\n")
        new_text = f"{above_text}{marker_line}\n\n{below_stripped}"
        if not new_text.endswith("\n"):
            new_text += "\n"
    else:
        new_text = f"{above_text}{marker_line}\n"
    path.write_text(new_text, encoding="utf-8")
    return sha


def _split_around_marker(plan_text: str) -> tuple[str, str]:
    """Split plan into ``(above_marker, below_marker)``.

    ``above_marker`` is the contract content with trailing blank lines trimmed
    and a single trailing newline preserved iff the original had one.
    ``below_marker`` is the workspace section verbatim (empty string when no
    marker is found).
    """
    if not plan_text:
        return plan_text, ""
    has_trailing_newline = plan_text.endswith("\n")
    lines = plan_text.splitlines()
    marker_idx = last_marker_index(lines, include_placeholder=True)
    if marker_idx is None:
        return plan_text, ""
    above = lines[:marker_idx]
    while above and not above[-1].strip():
        above.pop()
    above_text = "\n".join(above)
    if above and has_trailing_newline:
        above_text += "\n"
    below_lines = lines[marker_idx + 1 :]
    # Drop leading and trailing blank lines so a marker followed only by
    # whitespace produces an empty workspace (avoids stray blank rewrites).
    while below_lines and not below_lines[0].strip():
        below_lines.pop(0)
    while below_lines and not below_lines[-1].strip():
        below_lines.pop()
    if not below_lines:
        return above_text, ""
    below_text = "\n".join(below_lines)
    if has_trailing_newline:
        below_text += "\n"
    return above_text, below_text


def marker_is_stale(plan_path: str | Path) -> bool | None:
    """Return True if the plan has a marker whose hash no longer matches,
    False if the marker is valid, and None if there is no marker at all.
    """
    marker = read_marker(plan_path)
    if marker is None:
        return None
    _, recorded_sha = marker
    current_sha = compute_plan_hash(plan_path)
    return current_sha != recorded_sha
