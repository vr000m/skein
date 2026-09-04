#!/usr/bin/env python3
"""Thin CLI that writes the /review-plan review marker via the canonical,
byte-faithful hashing authority (``marker.py``).

This wrapper exists so /review-plan Step 7 never hand-computes the marker hash
in prose-following Python — the trap that dropped the newline above the marker
and produced a false "plan drift" (``9fa0989`` vs ``df8d891``). All hashing
lives in the bundled :mod:`marker` module, byte-identical to conduct's copy.

Usage:
    write-review-marker.py <plan-path>

Behaviour:
  * Aborts non-zero with a usage error if no plan path is given.
  * Aborts non-zero **without writing** if the plan has no review-marker line
    and no template placeholder divider (``_marker_line_span`` is ``None``) —
    the marker must never be silently buried below the workspace.
  * Otherwise calls ``write_marker(plan_path)`` and prints the recorded sha to
    stdout.

No hashing logic of its own.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from marker import _marker_line_span, write_marker


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        print(
            "write-review-marker: usage: write-review-marker.py <plan-path>",
            file=sys.stderr,
        )
        return 2

    plan_path = argv[1]

    try:
        text = open(plan_path, "rb").read().decode("utf-8")
    except OSError as exc:
        print(f"write-review-marker: cannot read {plan_path}: {exc}", file=sys.stderr)
        return 1

    if _marker_line_span(text) is None:
        print(
            "write-review-marker: no review-marker divider; cannot place marker safely",
            file=sys.stderr,
        )
        return 1

    sha = write_marker(plan_path)
    print(sha)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
