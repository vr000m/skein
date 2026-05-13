import sys
from pathlib import Path

# Make the skill package importable under its own directory without requiring
# the caller to set PYTHONPATH. Tests import ``parser``, ``marker``, ``lock``
# as top-level modules.
_SKILL_DIR = Path(__file__).resolve().parent.parent
if str(_SKILL_DIR) not in sys.path:
    sys.path.insert(0, str(_SKILL_DIR))


# ---------------------------------------------------------------------------
# LockAcquisitionCounter — Phase 2 test fixture
# ---------------------------------------------------------------------------
#
# Wraps ``conductor.StateLock`` so tests can assert how many times the
# conductor's ``with lock:`` block was entered during a run. The counter is
# the single observable signal for the "single-lock-acquisition under
# --autonomous" invariant (one acquire across all phases) vs. legacy mode
# (one acquire per ``--resume``).
#
# Injection seam: ``install(monkeypatch)`` patches the ``StateLock`` symbol
# referenced inside ``conductor`` so the wrapper sees every acquisition the
# conductor performs, regardless of how the underlying lock module is
# implemented (flock / mkdir fallback / etc.).
import pytest  # noqa: E402

from conductor import StateLock as _RealStateLock  # noqa: E402


class LockAcquisitionCounter:
    """Counts successful ``StateLock.acquire()`` calls inside ``conductor``.

    Usage::

        def test_something(repo, monkeypatch):
            counter = LockAcquisitionCounter.install(monkeypatch)
            conduct(...)
            assert counter.count == 1

    Implementation note: we wrap the real ``StateLock`` rather than replace
    it so the lock's contract (mutual exclusion, stale-break, etc.) is still
    exercised end-to-end. Only successful acquisitions are counted — a raised
    ``LockError`` does not increment.
    """

    def __init__(self) -> None:
        self.count = 0

    def install(monkeypatch) -> "LockAcquisitionCounter":  # type: ignore[misc]
        """Patch ``conductor.StateLock`` so its ``acquire`` increments the
        returned counter. Returns the live counter instance.
        """
        counter = LockAcquisitionCounter()
        real_cls = _RealStateLock

        class _CountingLock(real_cls):  # type: ignore[misc, valid-type]
            def acquire(self) -> None:  # type: ignore[override]
                super().acquire()
                counter.count += 1

        monkeypatch.setattr("conductor.StateLock", _CountingLock)
        return counter

    # ``install`` is used as a classmethod-style factory; expose it both ways
    # so ``LockAcquisitionCounter.install(mp)`` works without an instance.
    install = staticmethod(install)  # type: ignore[assignment]


@pytest.fixture
def lock_counter(monkeypatch) -> LockAcquisitionCounter:
    """Convenience fixture: patches ``conductor.StateLock`` and returns the
    live counter. Tests that need to observe lock acquisition counts during
    a ``conduct()`` invocation should request this fixture.
    """
    return LockAcquisitionCounter.install(monkeypatch)
