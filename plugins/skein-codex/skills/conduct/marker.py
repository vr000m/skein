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

MARKER_RE = re.compile(r"^<!-- reviewed: (\d{4}-\d{2}-\d{2}) @ ([0-9a-f]{40}) -->\s*$")
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


def _marker_line_span(plan_text: str) -> tuple[int, int] | None:
    """Return ``(start, end)`` byte offsets of the last unfenced marker (or
    placeholder) line, or ``None`` if no such line exists.

    ``start`` is the offset of the marker line's first character; ``end`` is
    the offset just past its line terminator. Offsets are reconstructed from
    ``splitlines(keepends=True)`` so they are exact even for CRLF input — the
    caller can slice ``plan_text`` byte-faithfully on either side.
    """
    in_fence = False
    pos = 0
    span = None
    for line in plan_text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        if FENCE_RE.match(content):
            in_fence = not in_fence
        elif not in_fence and (
            MARKER_RE.match(content) or MARKER_PLACEHOLDER_RE.match(content)
        ):
            span = (pos, pos + len(line))
        pos += len(line)
    return span


def strip_marker_for_hashing(plan_text: str) -> str:
    """Return the plan content above the marker line, ready for hashing.

    The marker line itself and **everything after it** are excluded — the
    workspace section (``## Progress``, ``## Findings``, etc.) lives below the
    marker and must not affect the hash. If no marker line is found, the plan
    is returned unchanged.

    **Byte-faithful.** The returned text is exactly ``plan_text`` truncated at
    the byte where the marker line begins — every byte above the marker is
    preserved verbatim, including blank lines immediately above it and the
    original line endings (LF or CRLF). This is the documented recipe ("take
    the plan with the marker line and everything after it stripped, pipe to
    ``git hash-object --stdin``"), so the hash this module computes equals
    ``git hash-object`` of the above-marker bytes that ``/review-plan`` writes
    and any byte-faithful external checker reproduces. Do **not** re-introduce
    trailing-blank trimming or ``splitlines``/``join`` normalization here: a
    plan with a blank line before its marker (the common markdown style) would
    then hash differently from what wrote it and report a false staleness.

    Locating the marker: scan for the last unfenced line that matches the
    marker regex (so a plan documenting marker syntax in prose earlier in the
    file is unaffected).
    """
    if not plan_text:
        return plan_text
    span = _marker_line_span(plan_text)
    if span is None:
        return plan_text
    return plan_text[: span[0]]


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

    Reads the file as bytes and decodes explicitly rather than via
    ``read_text``: ``read_text`` applies universal-newline translation
    (CRLF/CR → LF), which would silently rewrite line endings before hashing
    and make a CRLF plan hash differently from its on-disk bytes. The hash must
    match ``git hash-object`` of the literal above-marker bytes, so the read
    must be byte-faithful too.
    """
    plan = Path(plan_path).read_bytes().decode("utf-8")
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

    ``above_marker`` is the contract content **byte-faithful** — exactly the
    bytes above the marker line, blank lines and original line endings
    preserved. ``write_marker`` hashes these bytes, so the recorded hash equals
    what :func:`strip_marker_for_hashing` recomputes on the rewritten plan (the
    two must use the same byte-faithful slice or write/validate would disagree).
    ``below_marker`` is the workspace section with leading and trailing blank
    lines dropped (empty string when no marker is found, or when only
    whitespace follows the marker — avoids stray blank rewrites).
    """
    if not plan_text:
        return plan_text, ""
    span = _marker_line_span(plan_text)
    if span is None:
        return plan_text, ""
    above_text = plan_text[: span[0]]
    below_lines = plan_text[span[1] :].splitlines()
    # Drop leading and trailing blank lines so a marker followed only by
    # whitespace produces an empty workspace (avoids stray blank rewrites).
    while below_lines and not below_lines[0].strip():
        below_lines.pop(0)
    while below_lines and not below_lines[-1].strip():
        below_lines.pop()
    if not below_lines:
        return above_text, ""
    below_text = "\n".join(below_lines)
    if plan_text.endswith("\n"):
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
