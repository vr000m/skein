"""CI parity entrypoint detection (stdlib only)."""

from __future__ import annotations

from pathlib import Path
from typing import Optional


def _justfile_has_ci(path: Path) -> bool:
    try:
        text = path.read_text()
    except OSError:
        return False
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("ci:"):
            return True
        if stripped.startswith("ci ") and ":" in stripped.split(" ", 1)[-1]:
            return True
    return False


def _makefile_has_ci(path: Path) -> bool:
    try:
        text = path.read_text()
    except OSError:
        return False
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("ci:") or stripped.startswith("ci :"):
            return True
    return False


def _package_json_has_ci(path: Path) -> bool:
    try:
        text = path.read_text()
    except OSError:
        return False
    return '"scripts"' in text and '"ci"' in text


def detect_ci_entrypoint(repo_root: Path) -> Optional[tuple[str, str]]:
    """Return ``(kind, cmd)`` for the first detected local CI entrypoint."""
    justfile = repo_root / "justfile"
    if justfile.exists() and _justfile_has_ci(justfile):
        return ("just", "just ci")

    cap_justfile = repo_root / "Justfile"
    if cap_justfile.exists() and _justfile_has_ci(cap_justfile):
        return ("just", "just ci")

    makefile = repo_root / "Makefile"
    if makefile.exists() and _makefile_has_ci(makefile):
        return ("make", "make ci")

    package_json = repo_root / "package.json"
    if package_json.exists() and _package_json_has_ci(package_json):
        return ("npm", "npm run ci")

    if (repo_root / "Cargo.toml").exists():
        return ("cargo", "cargo test --all")

    return None
