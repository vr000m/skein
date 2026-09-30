"""Non-secret cache for stable Pi review-gate capability absence."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path

SCHEMA_VERSION = 1
STABLE_STATUS = "unavailable"


def fingerprint(parts: dict[str, str]) -> str:
    """Return a deterministic, non-secret fingerprint of capability inputs."""
    payload = json.dumps(parts, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def load(path: Path, key: str, current_fingerprint: str) -> dict[str, str] | None:
    try:
        _assert_no_symlink_path(path)
        value = json.loads(path.read_text())
    except (FileNotFoundError, OSError, ValueError):
        return None
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != SCHEMA_VERSION
        or not isinstance(value.get("entries"), dict)
    ):
        return None
    entry = value["entries"].get(key)
    if (
        not isinstance(entry, dict)
        or entry.get("status") != STABLE_STATUS
        or entry.get("fingerprint") != current_fingerprint
        or not isinstance(entry.get("reason"), str)
    ):
        return None
    return {"status": STABLE_STATUS, "reason": entry["reason"]}


def _assert_no_symlink_path(path: Path) -> None:
    current = path.anchor and Path(path.anchor) or Path()
    for component in path.parts[1:] if path.is_absolute() else path.parts:
        current /= component
        if current.is_symlink():
            raise ValueError("symlink in capability cache path")


def record(path: Path, key: str, current_fingerprint: str, reason: str) -> None:
    if not key or not reason or "\x00" in key or "\x00" in reason:
        raise ValueError("invalid capability cache entry")
    _assert_no_symlink_path(path.parent)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _assert_no_symlink_path(path)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    try:
        value = json.loads(path.read_text())
    except (FileNotFoundError, OSError, ValueError):
        value = {"schema_version": SCHEMA_VERSION, "entries": {}}
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != SCHEMA_VERSION
        or not isinstance(value.get("entries"), dict)
    ):
        value = {"schema_version": SCHEMA_VERSION, "entries": {}}
    value["entries"][key] = {
        "status": STABLE_STATUS,
        "fingerprint": current_fingerprint,
        "reason": reason,
    }
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def clear(path: Path) -> None:
    """Explicit operator refresh: remove all cached capability decisions."""
    try:
        path.unlink()
    except FileNotFoundError:
        pass
