"""CI parity entrypoint detection (stdlib only).

Phase 3 of the autonomous-mode plan: at end-of-plan, the conductor dispatches a
CI-parity worker that runs whatever the repo treats as "CI" locally. This
module owns the detection of which command to run.

Detection priority (workflows intentionally dropped — not locally executable
without external tooling like ``act``):

  1. ``just ci``           — ``justfile`` with a ``ci:`` recipe.
  2. ``make ci``           — ``Makefile`` with a ``ci:`` target.
  3. ``npm run ci``        — ``package.json`` with a ``"ci"`` script entry.
  4. ``cargo test --all``  — ``Cargo.toml`` present at the repo root.

Returns ``(kind, cmd)`` for the first match, or ``None`` if no entrypoint can
be detected. ``--ci-cmd CMD`` on ``ConductOptions`` bypasses this detection.
"""

from __future__ import annotations

from pathlib import Path


def _justfile_has_ci(path: Path) -> bool:
    try:
        text = path.read_text()
    except OSError:
        return False
    for line in text.splitlines():
        # Just recipes are headers at column zero. Lines with leading
        # whitespace are recipe bodies or continuations — they cannot
        # introduce a new recipe. Matching only column-zero ``ci:`` /
        # ``ci <args>:`` avoids false positives from ``define``-style
        # blocks or commented-out examples that happen to contain ``ci:``.
        if line.startswith("ci:") or line.startswith("ci "):
            # The "ci " form must be followed eventually by a colon on the
            # same line for it to be a recipe header.
            if line.startswith("ci:") or ":" in line.split(" ", 1)[-1]:
                return True
    return False


def _makefile_has_ci(path: Path) -> bool:
    try:
        text = path.read_text()
    except OSError:
        return False
    for line in text.splitlines():
        # Make targets sit at column zero; recipe bodies are tab-indented.
        # Restricting to column zero prevents matching ``ci:`` inside a
        # ``define``/``endef`` block, a here-doc, or any other indented
        # context where the literal would not be a real CI target.
        if line.startswith("ci:") or line.startswith("ci :"):
            return True
    return False


def _package_json_has_ci(path: Path) -> bool:
    try:
        text = path.read_text()
    except OSError:
        return False
    # Substring probe matches the conductor's existing detection style for
    # ``scripts.test`` / ``scripts.lint`` — avoids a hard json-parse dependency
    # on partially-valid files.
    return '"scripts"' in text and '"ci"' in text


def detect_ci_entrypoint(repo_root: Path) -> tuple[str, str] | None:
    """Return ``(kind, cmd)`` for the first CI entrypoint detected, else None.

    ``kind`` is one of ``"just"``, ``"make"``, ``"npm"``, ``"cargo"``. ``cmd``
    is the shell-ready command string.
    """
    justfile = repo_root / "justfile"
    if justfile.exists() and _justfile_has_ci(justfile):
        return ("just", "just ci")
    # Some repos use the capitalised ``Justfile`` form.
    cap_just = repo_root / "Justfile"
    if cap_just.exists() and _justfile_has_ci(cap_just):
        return ("just", "just ci")

    makefile = repo_root / "Makefile"
    if makefile.exists() and _makefile_has_ci(makefile):
        return ("make", "make ci")

    pkg = repo_root / "package.json"
    if pkg.exists() and _package_json_has_ci(pkg):
        return ("npm", "npm run ci")

    if (repo_root / "Cargo.toml").exists():
        return ("cargo", "cargo test --all")

    return None
