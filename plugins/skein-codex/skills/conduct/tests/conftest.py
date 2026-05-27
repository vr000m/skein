import sys
from pathlib import Path

import pytest

# Make the ``conduct`` package importable without requiring the caller to set
# PYTHONPATH. The parent skills directory goes on sys.path so tests import
# ``conduct.<module>`` rather than relying on flat top-level module names.
_SKILLS_DIR = Path(__file__).resolve().parents[2]
if str(_SKILLS_DIR) not in sys.path:
    sys.path.insert(0, str(_SKILLS_DIR))

import conduct.conductor as conductor  # noqa: E402
from conduct.lock import StateLock as _RealStateLock  # noqa: E402


class LockAcquisitionCounter:
    """Counts successful conductor StateLock acquisitions."""

    def __init__(self) -> None:
        self.count = 0

    @staticmethod
    def install(monkeypatch: pytest.MonkeyPatch) -> "LockAcquisitionCounter":
        counter = LockAcquisitionCounter()
        real_cls = _RealStateLock

        class _CountingLock(real_cls):  # type: ignore[misc, valid-type]
            def acquire(self) -> None:  # type: ignore[override]
                super().acquire()
                counter.count += 1

        monkeypatch.setattr(conductor, "StateLock", _CountingLock)
        return counter


@pytest.fixture
def lock_counter(monkeypatch: pytest.MonkeyPatch) -> LockAcquisitionCounter:
    return LockAcquisitionCounter.install(monkeypatch)
