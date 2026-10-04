"""Read-only executable pinning for Codex release preflight; never launches tools."""

from __future__ import annotations

import argparse
import grp
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

TRUSTED_ROOTS = (
    Path("/bin"),
    Path("/sbin"),
    Path("/usr/bin"),
    Path("/usr/sbin"),
    Path("/usr/libexec"),
    Path("/Library/Developer/CommandLineTools"),
    Path("/opt/homebrew/bin"),
    Path("/opt/homebrew/sbin"),
    Path("/opt/homebrew/Cellar"),
    Path("/usr/local/bin"),
    Path("/usr/local/sbin"),
    Path("/usr/local/Cellar"),
)
HOMEBREW_PREFIXES = (Path("/opt/homebrew"), Path("/usr/local"))
# Compiled Git exec paths use Homebrew opt aliases; only their resolved targets
# may be executables, and those still pass the canonical-root policy above.
LOOKUP_ROOTS = TRUSTED_ROOTS + tuple(prefix / "opt" for prefix in HOMEBREW_PREFIXES)


def within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def component_allowed(
    path: Path,
    executable: Path,
    info: os.stat_result,
    *,
    platform: str,
    uid: int,
    admin_gid: int | None,
) -> bool:
    """Only macOS admin-group Homebrew directories may be group-writable."""
    if info.st_uid not in (0, uid) or stat.S_ISLNK(info.st_mode):
        return False
    if info.st_mode & stat.S_IWOTH:
        return False
    if path == executable:
        return (
            stat.S_ISREG(info.st_mode)
            and bool(info.st_mode & 0o111)
            and not bool(info.st_mode & stat.S_IWGRP)
        )
    if not stat.S_ISDIR(info.st_mode):
        return False
    if not info.st_mode & stat.S_IWGRP:
        return True
    return (
        platform == "darwin"
        and admin_gid == 80
        and info.st_gid == admin_gid
        and any(
            within(path, prefix) and within(executable, prefix / "Cellar")
            for prefix in HOMEBREW_PREFIXES
        )
    )


def metadata(info: os.stat_result) -> dict:
    return {
        "device": info.st_dev,
        "inode": info.st_ino,
        "mode": info.st_mode,
        "uid": info.st_uid,
        "gid": info.st_gid,
    }


def pin(candidate: str) -> dict:
    path = Path(candidate)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("candidate must be an absolute path without '..'")
    if not any(within(path, root) for root in LOOKUP_ROOTS):
        raise ValueError("candidate is outside fixed trusted search roots")
    canonical = path.resolve(strict=True)
    if not any(within(canonical, root) for root in TRUSTED_ROOTS):
        raise ValueError("canonical executable is outside fixed trusted roots")
    admin_gid = None
    if sys.platform == "darwin":
        try:
            admin_gid = grp.getgrnam("admin").gr_gid
        except KeyError:
            pass
    components = []
    for component in (*reversed(canonical.parents), canonical):
        info = component.lstat()
        if not component_allowed(
            component,
            canonical,
            info,
            platform=sys.platform,
            uid=os.getuid(),
            admin_gid=admin_gid,
        ):
            raise ValueError(f"unsafe executable path component: {component}")
        components.append({"path": str(component), **metadata(info)})
    leaf = canonical.lstat()
    digest = hashlib.sha256()
    descriptor = os.open(canonical, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if metadata(before) != metadata(leaf):
            raise ValueError("executable identity changed before hash read")
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
        if (metadata(before), before.st_size, before.st_mtime_ns) != (
            metadata(after),
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ValueError("executable changed during hash read")
    for component in components:
        info = Path(component["path"]).lstat()
        if metadata(info) != {key: component[key] for key in metadata(info)}:
            raise ValueError("executable path changed during pinning")
    return {
        "candidate": candidate,
        "canonical": str(canonical),
        "components": components,
        "sha256": digest.hexdigest(),
    }


def verify(record: dict) -> dict:
    actual = pin(record["candidate"])
    if actual != record:
        raise ValueError("pinned executable identity drifted")
    return actual


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--candidate", action="append")
    mode.add_argument("--verify-stdin", action="store_true")
    args = parser.parse_args()
    try:
        if args.verify_stdin:
            records = json.load(sys.stdin)["pins"]
            if not isinstance(records, list) or not records:
                raise ValueError("pins must be a nonempty list")
            pins = [verify(record) for record in records]
        else:
            pins = [pin(candidate) for candidate in args.candidate]
        print(json.dumps({"pins": pins}, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": str(error)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
