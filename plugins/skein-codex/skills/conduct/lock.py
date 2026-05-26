"""Advisory lockfile helper for the conduct skill.

Primary mechanism: ``fcntl.flock`` on a lockfile fd — portable across macOS and
Linux with no external dependency. ``flock(1)`` is not used because it is not
present on macOS by default. Fallback if ``fcntl`` is unavailable: atomic
``mkdir`` lockdir.

Fallback ``mkdir`` locks older than ``STALE_SECONDS`` are broken only when the
pid recorded in the lockdir is absent or dead. Flock-backed lockfiles are never
unlinked by age alone.

CLI usage:

    python3 lock.py acquire <lockfile>   # exit 0 on acquire; prints pid
    python3 lock.py status  <lockfile>   # exit 0 if free, 1 if held

Python usage::

    from conduct.lock import StateLock
    with StateLock(path) as lock:
        # ... exclusive section ...
"""

from __future__ import annotations

import errno
import os
import sys
import time
from pathlib import Path

try:
    import fcntl  # POSIX only
except ImportError:  # pragma: no cover - Windows has no fcntl
    fcntl = None  # type: ignore[assignment]

STALE_SECONDS = 60 * 60  # 1 hour


class LockError(RuntimeError):
    pass


def _nofollow_flag() -> int:
    return getattr(os, "O_NOFOLLOW", 0)


class StateLock:
    """Advisory lock on a given lockfile path.

    Prefers ``fcntl.flock``. Falls back to atomic ``mkdir`` of ``<path>.lockdir``
    when ``fcntl`` is unavailable.
    """

    def __init__(self, path: str | os.PathLike[str]):
        self.path = Path(path)
        self._fd: int | None = None
        self._lockdir: Path | None = None

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if fcntl is not None:
            self._acquire_flock()
        else:
            self._break_stale_lockdir()
            self._acquire_mkdir()

    def release(self) -> None:
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)  # type: ignore[union-attr]
            finally:
                os.close(self._fd)
                self._fd = None
                try:
                    self.path.unlink()
                except FileNotFoundError:
                    pass
        if self._lockdir is not None:
            try:
                pid_file = self._lockdir / "pid"
                if pid_file.exists():
                    pid_file.unlink()
                self._lockdir.rmdir()
            except FileNotFoundError:
                pass
            self._lockdir = None

    def __enter__(self) -> "StateLock":
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.release()

    def _acquire_flock(self) -> None:
        fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR | _nofollow_flag(), 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # type: ignore[union-attr]
        except OSError as err:
            os.close(fd)
            if err.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise LockError(f"Lock held: {self.path}") from None
            raise
        os.ftruncate(fd, 0)
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, f"{os.getpid()}\n".encode())
        os.fsync(fd)
        self._fd = fd

    def _acquire_mkdir(self) -> None:
        lockdir = self.path.with_suffix(self.path.suffix + ".lockdir")
        try:
            lockdir.mkdir()
        except FileExistsError:
            raise LockError(f"Lock held: {lockdir}") from None
        (lockdir / "pid").write_text(f"{os.getpid()}\n")
        self._lockdir = lockdir

    def _break_stale_lockdir(self) -> None:
        lockdir = self.path.with_suffix(self.path.suffix + ".lockdir")
        if not lockdir.exists():
            return
        try:
            age = time.time() - lockdir.stat().st_mtime
        except FileNotFoundError:
            return
        if age <= STALE_SECONDS:
            return
        if _lockdir_pid_is_running(lockdir):
            return
        sys.stderr.write(
            f"conduct: breaking stale lock {lockdir} (age={int(age)}s)\n"
        )
        for child in lockdir.iterdir():
            child.unlink()
        lockdir.rmdir()


def _read_lockdir_pid(lockdir: Path) -> int | None:
    pid_file = lockdir / "pid"
    try:
        raw = pid_file.read_text().strip()
    except OSError:
        return None
    if not raw.isdigit():
        return None
    pid = int(raw)
    return pid if pid > 0 else None


def _pid_is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _lockdir_pid_is_running(lockdir: Path) -> bool:
    pid = _read_lockdir_pid(lockdir)
    if pid is None:
        return False
    return _pid_is_running(pid)


def lock_is_held(path: str | os.PathLike[str]) -> bool:
    lock_path = Path(path)
    lockdir = lock_path.with_suffix(lock_path.suffix + ".lockdir")
    if lockdir.exists() and _lockdir_pid_is_running(lockdir):
        return True
    if not lock_path.exists():
        return False
    if fcntl is None:
        return lockdir.exists()
    try:
        fd = os.open(str(lock_path), os.O_RDWR | _nofollow_flag())
    except FileNotFoundError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # type: ignore[union-attr]
        fcntl.flock(fd, fcntl.LOCK_UN)  # type: ignore[union-attr]
        return False
    except OSError as err:
        if err.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
            return True
        raise
    finally:
        os.close(fd)


def _cli_acquire(path: str) -> int:
    lock = StateLock(path)
    try:
        lock.acquire()
    except LockError as err:
        sys.stderr.write(f"{err}\n")
        return 1
    sys.stdout.write(f"{os.getpid()}\n")
    return 0


def _cli_status(path: str) -> int:
    return 1 if lock_is_held(path) else 0


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in {"acquire", "status"}:
        sys.stderr.write("usage: lock.py {acquire|status} <lockfile>\n")
        return 2
    action, path = argv[1], argv[2]
    if action == "acquire":
        return _cli_acquire(path)
    return _cli_status(path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
