"""Contract test authored against the fixture-plan.md Integration Seams row:

    Writer: slice-A | Interface: from fixture_pkg.adder import add
            | Signature: add(a: int, b: int) -> int

This is what a test-writer subagent (or, under the current fallback, the worker
itself) would author from the Writer-designated seam row alone -- it asserts the
contract's behaviour, not any particular implementation's internals.

Runnable two ways, with no third-party dependencies required for either:
  - `python3 -m pytest contract_test_adder.py` (if pytest is available)
  - `python3 contract_test_adder.py` (plain script; exits 0 on success, non-zero
    with a traceback on the first failed assertion)
"""

import sys

from fixture_pkg.adder import add


def test_add_positive():
    assert add(2, 3) == 5


def test_add_zero():
    assert add(0, 0) == 0


def test_add_inverse():
    assert add(-1, 1) == 0


if __name__ == "__main__":
    test_add_positive()
    test_add_zero()
    test_add_inverse()
    sys.exit(0)
