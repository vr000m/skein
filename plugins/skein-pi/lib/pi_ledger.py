"""Small guarded convergence ledger for the Pi gauntlet.

This is intentionally a state adapter, not a second review implementation.
The Pi skill records validated gate outcomes and uses the ledger only for
round/resume decisions.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

MAX_ROUNDS = 10
TERMINAL = frozenset({"success", "partial", "degraded", "zero_runnable", "cap"})


def _guard(path: Path) -> None:
    current = Path(path.anchor) if path.is_absolute() else Path()
    parts = path.parts[1:] if path.is_absolute() else path.parts
    for component in parts:
        current /= component
        if current.is_symlink():
            raise ValueError("symlink in Pi gauntlet ledger path")


def _write(path: Path, value: dict[str, object]) -> None:
    _guard(path.parent)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _guard(path)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


class PiLedger:
    def __init__(self, path: Path, target: str):
        if not target or "\x00" in target:
            raise ValueError("invalid ledger target")
        self.path = path
        self.target = target

    def read(self) -> dict[str, object] | None:
        _guard(self.path)
        try:
            value = json.loads(self.path.read_text())
        except FileNotFoundError:
            return None
        if (
            not isinstance(value, dict)
            or type(value.get("schema_version")) is not int
            or value.get("schema_version") != 1
            or value.get("target") != self.target
            or not isinstance(value.get("rounds"), list)
        ):
            raise ValueError("invalid Pi gauntlet ledger")
        rounds = value["rounds"]
        if len(rounds) > MAX_ROUNDS:
            raise ValueError("Pi gauntlet ledger exceeds round cap")
        for index, outcome in enumerate(rounds, start=1):
            if (
                not isinstance(outcome, dict)
                or type(outcome.get("round")) is not int
                or outcome.get("round") != index
            ):
                raise ValueError("invalid Pi gauntlet round")
            self._validate_round(outcome)
            if index < len(rounds) and outcome.get("status") in TERMINAL:
                raise ValueError("round follows terminal Pi gauntlet decision")
        decision = value.get("decision")
        if not rounds:
            if decision != "no-rounds":
                raise ValueError("invalid empty Pi gauntlet decision")
        elif decision == "continue":
            if len(rounds) >= MAX_ROUNDS or rounds[-1].get("status") != "continue":
                raise ValueError("invalid continuing Pi gauntlet decision")
        elif decision == "success":
            if rounds[-1].get("status") != "success":
                raise ValueError("success decision lacks successful round")
        elif decision in {"partial", "degraded", "zero_runnable"}:
            if rounds[-1].get("status") != decision:
                raise ValueError("terminal decision lacks matching round")
        elif decision == "cap":
            if len(rounds) != MAX_ROUNDS or rounds[-1].get("status") != "continue":
                raise ValueError("cap decision before round limit")
        else:
            raise ValueError("invalid Pi gauntlet decision")
        return value

    def init(self, *, fresh: bool = False) -> dict[str, object]:
        if self.path.exists() and not fresh:
            raise FileExistsError(self.path)
        value = {
            "schema_version": 1,
            "target": self.target,
            "rounds": [],
            "decision": "no-rounds",
        }
        _write(self.path, value)
        return value

    @staticmethod
    def _validate_round(outcome: dict[str, object]) -> None:
        status = outcome.get("status")
        if status not in {
            "continue",
            "success",
            "partial",
            "degraded",
            "zero_runnable",
        }:
            raise ValueError("invalid Pi gauntlet round status")
        gates = outcome.get("gates")
        if not isinstance(gates, list) or not gates:
            raise ValueError("gate evidence is required")
        finding_count = 0
        for gate in gates:
            if not isinstance(gate, dict) or not isinstance(gate.get("gate"), str):
                raise ValueError("invalid Pi gauntlet gate evidence")  # noqa: TRY004
            if gate.get("status") not in {"passed", "findings", "skipped", "degraded"}:
                raise ValueError("invalid Pi gauntlet gate status")
            findings = gate.get("findings", [])
            if not isinstance(findings, list):
                raise ValueError("invalid Pi gauntlet findings")  # noqa: TRY004
            finding_count += len(findings)
        if type(outcome.get("findings_count", finding_count)) is not int:
            raise ValueError("invalid Pi gauntlet finding count")
        if outcome.get("findings_count", finding_count) != finding_count:
            raise ValueError("inconsistent Pi gauntlet finding count")
        if status == "success" and (
            any(gate["status"] != "passed" for gate in gates) or finding_count != 0
        ):
            raise ValueError("success requires clean full coverage")
        if status == "zero_runnable" and any(
            gate["status"] != "skipped" for gate in gates
        ):
            raise ValueError("zero-runnable outcome has runnable gate")

    def append(self, outcome: dict[str, object]) -> str:
        self._validate_round(outcome)
        value = self.read() or self.init()
        current_decision = str(value.get("decision", "no-rounds"))
        if current_decision in TERMINAL or current_decision == "cap":
            raise ValueError("cannot append to terminal Pi gauntlet ledger")
        rounds = value["rounds"]
        assert isinstance(rounds, list)
        if len(rounds) >= MAX_ROUNDS:
            value["decision"] = "cap"
            _write(self.path, value)
            return "cap"
        rounds.append(dict(outcome, round=len(rounds) + 1))
        status = str(outcome.get("status", "degraded"))
        value["decision"] = (
            "cap"
            if len(rounds) >= MAX_ROUNDS and status == "continue"
            else status
            if status in TERMINAL
            else "continue"
        )
        _write(self.path, value)
        return str(value["decision"])

    def decision(self) -> str:
        value = self.read()
        return "no-rounds" if value is None else str(value.get("decision", "continue"))
