"""Test-runner subprocess wrapper with portable wall-clock timeout.

Replaces the previous shell-out to ``timeout``/``gtimeout`` (which is missing
on stock macOS — the documented --test-timeout flag silently degraded to no
enforcement). Uses ``subprocess.run(timeout=...)`` so behaviour is identical
across Linux and macOS without the coreutils dependency.

The conductor calls ``run_tests`` from Bash via:

    uv run python -m conduct.runner '<cmd>' --timeout <secs>

or imports it directly when running inline. Both paths return the same
TestResult shape, so handback formatting can be uniform.
"""

from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass


@dataclass
class TestResult:
    returncode: int  # 0 = pass; non-zero = fail; -1 sentinel = timed out
    output: str  # stdout + stderr, merged in invocation order
    timed_out: bool
    duration_seconds: float


def run_tests(command: str, timeout: float = 300.0) -> TestResult:
    """Run ``command`` via the shell, enforce wall clock, return a TestResult.

    The command runs through ``/bin/sh -c`` so phase Test command slots that
    rely on shell features (pipes, `&&`, env vars) keep working.
    """
    import time

    start = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = time.monotonic() - start
        # exc.stdout/stderr are bytes-or-None even with text=True (Python quirk).
        out = _decode(exc.stdout) + _decode(exc.stderr)
        return TestResult(
            returncode=-1,
            output=out + f"\n[conduct] test command exceeded {timeout:.0f}s wall clock; killed.\n",
            timed_out=True,
            duration_seconds=elapsed,
        )
    elapsed = time.monotonic() - start
    return TestResult(
        returncode=completed.returncode,
        output=(completed.stdout or "") + (completed.stderr or ""),
        timed_out=False,
        duration_seconds=elapsed,
    )


def _decode(buf: object) -> str:
    if buf is None:
        return ""
    if isinstance(buf, bytes):
        return buf.decode("utf-8", errors="replace")
    return str(buf)


def _main(argv: list[str]) -> int:
    """CLI entry: ``python runner.py <cmd> [--timeout S]``.

    Prints output to stdout, exits with the test command's returncode (124 on
    timeout, mirroring GNU coreutils ``timeout``).
    """
    if len(argv) < 2:
        print("usage: runner.py '<test-command>' [--timeout SECS]", file=sys.stderr)
        return 2
    cmd = argv[1]
    timeout = 300.0
    if len(argv) >= 4 and argv[2] == "--timeout":
        timeout = float(argv[3])
    result = run_tests(cmd, timeout=timeout)
    sys.stdout.write(result.output)
    sys.stdout.flush()
    return 124 if result.timed_out else result.returncode


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(_main(sys.argv))
