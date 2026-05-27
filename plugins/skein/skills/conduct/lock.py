"""Advisory lockfile helper for the conduct skill.

Primary mechanism: ``fcntl.flock`` on a lockfile fd — portable across macOS and
Linux with no external dependency. ``flock(1)`` is not used because it is not
present on macOS by default. Fallback if ``fcntl`` is unavailable: atomic
``mkdir`` lockdir.

Stale locks older than ``STALE_SECONDS`` are broken with a warning printed to
stderr.

CLI usage:

    python3 lock.py acquire <lockfile>   # exit 0 on acquire; prints pid
    python3 lock.py release <lockfile>   # exit 0 on release
    python3 lock.py status  <lockfile>   # exit 0 if free, 1 if held

Python usage::

    from lock import StateLock
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
        self._break_stale()

        if fcntl is not None:
            self._acquire_flock()
        else:
            self._acquire_mkdir()

    def release(self) -> None:
        # Do NOT unlink the lockfile on release. Unlinking between LOCK_UN and
        # the next acquirer's O_CREAT opens a race where two processes can
        # flock distinct inodes under the same path. The stale-break sweeper
        # handles left-over lockfiles on the next acquire.
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)  # type: ignore[union-attr]
            finally:
                os.close(self._fd)
                self._fd = None
        if self._lockdir is not None:
            # Remove pid file first, then rmdir. Still racy in principle, but
            # the mkdir fallback only fires when fcntl is unavailable.
            try:
                (self._lockdir / "pid").unlink()
            except FileNotFoundError:
                pass
            try:
                self._lockdir.rmdir()
            except (FileNotFoundError, OSError):
                pass
            self._lockdir = None

    def __enter__(self) -> "StateLock":
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.release()

    def _acquire_flock(self) -> None:
        fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # type: ignore[union-attr]
        except OSError as err:
            os.close(fd)
            if err.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise LockError(f"Lock held: {self.path}") from None
            raise
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

    def _break_stale(self) -> None:
        candidates: list[Path] = []
        if self.path.exists():
            candidates.append(self.path)
        lockdir = self.path.with_suffix(self.path.suffix + ".lockdir")
        if lockdir.exists():
            candidates.append(lockdir)

        now = time.time()
        for candidate in candidates:
            try:
                # Use lstat so a symlink doesn't mask a live target.
                st = candidate.lstat()
            except FileNotFoundError:
                continue
            # Refuse to break a lock whose entry is a symlink — that is almost
            # certainly an attack or a misconfigured workspace, not a stale
            # lock we should silently remove.
            if candidate.is_symlink():
                sys.stderr.write(
                    f"conduct: refusing to break symlinked lock entry {candidate}\n"
                )
                continue
            age = now - st.st_mtime
            if age <= STALE_SECONDS:
                continue
            if not _holder_is_dead(candidate):
                # PID recorded in the lockfile/pid file is still alive, or
                # another process holds flock. Don't break.
                continue
            sys.stderr.write(
                f"conduct: breaking stale lock {candidate} (age={int(age)}s)\n"
            )
            if candidate.is_dir():
                for child in candidate.iterdir():
                    if child.is_symlink():
                        continue
                    try:
                        child.unlink()
                    except FileNotFoundError:
                        pass
                try:
                    candidate.rmdir()
                except OSError:
                    pass
            else:
                try:
                    candidate.unlink()
                except FileNotFoundError:
                    pass


def _holder_is_dead(candidate: Path) -> bool:
    """Best-effort: True if no live process claims this lock.

    For fcntl lockfiles: probe ``flock(LOCK_EX|LOCK_NB)``. Success = no holder.
    For mkdir lockdirs: read ``pid`` file and ``os.kill(pid, 0)``.
    """
    try:
        if candidate.is_file() and fcntl is not None:
            fd = os.open(str(candidate), os.O_RDWR | os.O_NOFOLLOW)
            try:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # type: ignore[union-attr]
                    fcntl.flock(fd, fcntl.LOCK_UN)  # type: ignore[union-attr]
                    return True  # nobody holds it
                except OSError:
                    return False
            finally:
                os.close(fd)
        if candidate.is_dir():
            pid_file = candidate / "pid"
            try:
                pid = int(pid_file.read_text().strip())
            except (FileNotFoundError, ValueError):
                return True
            try:
                os.kill(pid, 0)
                return False  # signal delivered → process exists
            except ProcessLookupError:
                return True
            except PermissionError:
                return False  # exists but owned by another user
    except OSError:
        pass
    return True


def _cli_acquire(path: str) -> int:
    lock = StateLock(path)
    try:
        lock.acquire()
    except LockError as err:
        sys.stderr.write(f"{err}\n")
        return 1
    sys.stdout.write(f"{os.getpid()}\n")
    return 0


def _cli_release(path: str) -> int:
    lock_path = Path(path)
    lockdir = lock_path.with_suffix(lock_path.suffix + ".lockdir")
    if lockdir.exists():
        if lockdir.is_symlink():
            sys.stderr.write(
                f"conduct: refusing to release symlinked lockdir {lockdir}\n"
            )
            return 1
        for child in lockdir.iterdir():
            if child.is_symlink():
                continue
            try:
                child.unlink()
            except FileNotFoundError:
                pass
        try:
            lockdir.rmdir()
        except OSError:
            pass
    elif lock_path.exists() and not lock_path.is_symlink():
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass
    return 0


def _cli_status(path: str) -> int:
    lock_path = Path(path)
    lockdir = lock_path.with_suffix(lock_path.suffix + ".lockdir")
    if lockdir.exists():
        return 1
    if not lock_path.exists():
        return 0
    if fcntl is None:
        return 1
    fd = os.open(str(lock_path), os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # type: ignore[union-attr]
        fcntl.flock(fd, fcntl.LOCK_UN)  # type: ignore[union-attr]
        return 0
    except OSError:
        return 1
    finally:
        os.close(fd)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in {"acquire", "release", "status"}:
        sys.stderr.write("usage: lock.py {acquire|release|status} <lockfile>\n")
        return 2
    action, path = argv[1], argv[2]
    if action == "acquire":
        return _cli_acquire(path)
    if action == "release":
        return _cli_release(path)
    return _cli_status(path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
