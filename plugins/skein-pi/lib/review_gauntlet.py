"""Pi-native review-gauntlet capability and routing primitives.

The module is deliberately independent of the Pi SDK.  The Pi skill owns the
interactive orchestration; this module owns the safety-critical decisions that
must be deterministic and testable without a live provider.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass

import capability_cache

STABLE_UNAVAILABLE_REASONS = frozenset(
    {"gate_not_installed", "executable_missing", "skill_not_registered"}
)
TRANSIENT_REASONS = frozenset(
    {
        "timeout",
        "authentication_failed",
        "parse_error",
        "process_failed",
        "operator_declined",
    }
)


@dataclass(frozen=True)
class GateCapability:
    name: str
    status: str  # available | unavailable | error
    reason: str | None = None
    cached: bool = False


@dataclass(frozen=True)
class GateOutcome:
    gate: str
    status: str  # passed | findings | skipped | degraded
    reason: str | None = None


@dataclass(frozen=True)
class Coverage:
    outcomes: tuple[GateOutcome, ...]
    runnable: int
    skipped: int
    degraded: int

    @property
    def clean_full_coverage(self) -> bool:
        return (
            self.runnable > 0
            and self.skipped == 0
            and self.degraded == 0
            and all(item.status == "passed" for item in self.outcomes)
        )


def probe(
    gate: str,
    *,
    fingerprint: str,
    cache_path,
    discover: Callable[[], tuple[bool, str | None]],
    refresh: bool = False,
) -> GateCapability:
    """Probe a gate, reusing only a fingerprint-matched stable absence.

    ``discover`` must return ``(available, reason)``.  A false result is cached
    only for a reason in ``STABLE_UNAVAILABLE_REASONS``; all other failures are
    returned as errors and are intentionally not cached.
    """
    if refresh:
        try:
            capability_cache.clear_entry(cache_path, gate)
        except (OSError, ValueError):
            return GateCapability(gate, "error", "capability_cache_refresh_failed")
    else:
        try:
            cached = capability_cache.load(cache_path, gate, fingerprint)
        except (OSError, ValueError):
            return GateCapability(gate, "error", "capability_cache_read_failed")
        if cached and cached["reason"] in STABLE_UNAVAILABLE_REASONS:
            return GateCapability(gate, "unavailable", cached["reason"], cached=True)
    try:
        available, reason = discover()
    except Exception as exc:  # noqa: BLE001 - probe failures are degraded
        return GateCapability(gate, "error", type(exc).__name__)
    if available:
        return GateCapability(gate, "available")
    if reason in STABLE_UNAVAILABLE_REASONS:
        try:
            capability_cache.record(cache_path, gate, fingerprint, reason)
        except (OSError, ValueError):
            return GateCapability(gate, "error", "capability_cache_write_failed")
        return GateCapability(gate, "unavailable", reason)
    return GateCapability(gate, "error", reason or "probe_inconclusive")


def coverage(
    capabilities: Iterable[GateCapability], outcomes: Iterable[GateOutcome] = ()
) -> Coverage:
    caps = tuple(capabilities)
    supplied = {item.gate: item for item in outcomes}
    rows: list[GateOutcome] = []
    for cap in caps:
        if cap.status == "unavailable":
            rows.append(GateOutcome(cap.name, "skipped", cap.reason))
        elif cap.status == "error":
            rows.append(GateOutcome(cap.name, "degraded", cap.reason))
        else:
            rows.append(
                supplied.get(cap.name, GateOutcome(cap.name, "degraded", "no_outcome"))
            )
    return Coverage(
        tuple(rows),
        sum(cap.status == "available" for cap in caps),
        sum(row.status == "skipped" for row in rows),
        sum(row.status == "degraded" for row in rows),
    )


def zero_runnable_stop(result: Coverage) -> str | None:
    """Return a visible stop reason instead of entering convergence."""
    if result.runnable == 0:
        return "zero_runnable_gates"
    return None


def fixer_request(
    findings: list[Mapping[str, object]],
    *,
    plan: str | None = None,
    snapshots: Mapping[str, str] | None = None,
) -> dict[str, object]:
    """Build the only request shape the Pi extension accepts for a fixer.

    The fixer is a normal Pi isolated worker, not a nested review orchestrator.
    Credentials, model selection, paths and tools are deliberately absent from
    this request and are supplied by the trusted extension after approval.
    """
    if not findings:
        raise ValueError("fixer requires at least one finding")
    if any("auto_fix" in finding for finding in findings):
        raise ValueError("Pi gauntlet does not accept auto_fix proposals")
    contract = {
        "kind": "review-gauntlet-fixer",
        "plan": plan,
        "findings": [dict(finding) for finding in findings],
        "snapshots": dict(snapshots or {}),
        "constraints": {
            "no_nested_dispatch": True,
            "report_root_cause": True,
            "require_regression_test": True,
            "return_claimed_findings": True,
            "application": "return a validated patch proposal; main session applies it",
        },
    }
    return {
        "role": "mechanical",
        "prompt": (
            "Apply the supplied review findings only after checking the live target. "
            "Return one accepted worker envelope with findings: [] and an "
            "artifact containing JSON keys schema_version, status, summary, "
            "claimed, patches, and blast_radius. Do not dispatch workers, "
            "write files, or claim an edit was applied. INPUT="
            + json.dumps(contract, sort_keys=True)
        ),
    }


def validate_fixer_result(
    envelope: Mapping[str, object],
    expected_findings: Iterable[Mapping[str, object]] | None = None,
) -> dict[str, object]:
    """Validate the proposal encoded inside the generic worker envelope."""
    if envelope.get("status") != "completed":
        raise ValueError("fixer_worker_not_completed")
    model_result = envelope.get("result")
    if not isinstance(model_result, Mapping):
        raise ValueError("fixer_result_missing")  # noqa: TRY004
    if model_result.get("status") != "ok" or model_result.get("findings") != []:
        raise ValueError("fixer_result_envelope_invalid")
    artifact = model_result.get("artifact")
    if not isinstance(artifact, Mapping) or artifact.get("format") != "markdown":
        raise ValueError("fixer_artifact_invalid")
    try:
        proposal = json.loads(str(artifact.get("content", "")))
    except (TypeError, ValueError) as exc:
        raise ValueError("fixer_proposal_invalid") from exc
    if not isinstance(proposal, dict) or set(proposal) != {
        "schema_version",
        "status",
        "summary",
        "claimed",
        "patches",
        "blast_radius",
    }:
        raise ValueError("fixer_proposal_invalid")
    if (
        type(proposal["schema_version"]) is not int
        or proposal["schema_version"] != 1
        or proposal["status"] != "ok"
    ):
        raise ValueError("fixer_proposal_invalid")
    if not isinstance(proposal["summary"], str) or not isinstance(
        proposal["claimed"], list
    ):
        raise ValueError("fixer_proposal_invalid")  # noqa: TRY004
    if (
        not isinstance(proposal["patches"], list)
        or not isinstance(proposal["blast_radius"], str)
        or proposal["blast_radius"] not in {"local", "structural"}
    ):
        raise ValueError("fixer_proposal_invalid")
    if proposal["patches"] and not proposal["claimed"]:
        raise ValueError("fixer_patches_without_claims")
    for claim in proposal["claimed"]:
        if not isinstance(claim, dict) or set(claim) != {
            "file",
            "line",
            "category",
            "summary",
            "root_cause",
            "regression_test",
        }:
            raise ValueError("fixer_claim_invalid")
        if (
            not isinstance(claim["file"], str)
            or (claim["line"] is not None and type(claim["line"]) is not int)
            or not all(
                isinstance(claim[key], str) and claim[key].strip()
                for key in ("category", "summary", "root_cause", "regression_test")
            )
        ):
            raise ValueError("fixer_claim_invalid")
    claim_files = {claim["file"] for claim in proposal["claimed"]}
    expected = (
        {
            (finding.get("file"), finding.get("line"), finding.get("category"))
            for finding in expected_findings
        }
        if expected_findings is not None
        else None
    )
    for claim in proposal["claimed"]:
        if (
            expected is not None
            and (claim["file"], claim["line"], claim["category"]) not in expected
        ):
            raise ValueError("fixer_claim_not_in_batch")
    for patch in proposal["patches"]:
        if not isinstance(patch, dict) or set(patch) != {
            "file",
            "old_text",
            "new_text",
        }:
            raise ValueError("fixer_patch_invalid")
        if (
            not isinstance(patch["file"], str)
            or patch["file"] not in claim_files
            or not patch["file"]
            or patch["file"].startswith("/")
            or ".." in patch["file"].replace("\\", "/").split("/")
            or not isinstance(patch["old_text"], str)
            or not isinstance(patch["new_text"], str)
        ):
            raise ValueError("fixer_patch_invalid")
    return proposal
