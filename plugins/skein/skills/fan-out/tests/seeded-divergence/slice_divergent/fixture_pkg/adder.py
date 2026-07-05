"""Divergent implementation of the fixture-plan.md Writer contract.

Deliberately violates the contract (`add(a: int, b: int) -> int` should return
`a + b`) by returning `a - b` instead, so the contract test's assertions fail. This
proves the R6 mechanism: a contract-derived test surfaces an implementation that
diverges from its contract, rather than being silently ratified because the same
agent wrote both the code and the test.
"""


def add(a: int, b: int) -> int:
    return a - b
