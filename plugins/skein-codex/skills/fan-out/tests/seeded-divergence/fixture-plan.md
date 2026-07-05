# Fixture Plan: Seeded Divergence for R6 Contract Tests

This is a minimal, two-slice fixture plan used only by
`plugins/skein-codex/skills/fan-out/tests/run-seeded-divergence.sh` to prove the
R6 mechanism deterministically: a contract-derived test fails against a divergent
implementation and passes against a conformant one. It is not a real dev plan and
is never fed to `/fan-out` or `/dev-plan`.

## Implementation Checklist

- [ ] Slice A (conformant): implement `add(a, b)` per the contract below.
- [ ] Slice B (divergent): implement `add(a, b)` — deliberately violates the
      contract (used only to prove the runner detects contract failures).

## Integration Seams

| Writer | Interface | Signature |
|---|---|---|
| slice-A | `from fixture_pkg.adder import add` | `add(a: int, b: int) -> int` |
| slice-B | `from fixture_pkg.adder import add` | `add(a: int, b: int) -> int` |

Both slices claim the same Writer interface on purpose: `slice_conformant/` honors
it (`add` returns `a + b`), `slice_divergent/` violates it (`add` returns `a - b`).
The contract test (`contract_test_adder.py`) is authored once, against the seam row
above, and run against both slice directories via `PYTHONPATH` — exactly as a
test-writer subagent would author one test file to the Writer-designated seam and
the worker would run it against its own implementation.
