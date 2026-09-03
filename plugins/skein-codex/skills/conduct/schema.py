"""Subagent report parsing and validation.

Anchors on the LAST fenced ```json block in the subagent's output (the schema
example earlier in the prompt would otherwise capture the first match), parses
it, and validates against the role-specific schema. Pure stdlib — no jsonschema
dependency.

Validation rules are deliberately narrow: they catch the failure modes that
caused real conductor breakage (missing keys, wrong types, role mismatch) and
ignore extra keys, since prompts may evolve faster than the schema.
"""

from __future__ import annotations

import json
import re
from typing import Any, NamedTuple

# Matches a fenced ```json block. Non-greedy body so adjacent blocks parse
# independently. We use re.findall + take the last match for "anchor on LAST".
_JSON_FENCE_RE = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)


class SchemaError(ValueError):
    """Raised when a subagent report is missing, unparseable, or invalid."""


_COMMON_REQUIRED = {
    "role": str,
    "phase_position": int,
    "phase_label": str,
    "flags": dict,
}


class RoleSpec(NamedTuple):
    """A role's schema in one place: required keys plus its flag substructure.

    ``flags_required is None`` means the role does not emit a `flags` object
    at all (reviewer, ci-parity — one-shot/advisory, no flag-driven branching
    in the conductor). Co-locating both in one entry, rather than three
    separate role-keyed dicts, means there is nothing to keep in sync: a role
    with a flag schema but no ``"flags"`` key in ``required`` (or vice versa)
    is a contradiction in the same tuple, not a cross-table drift that a
    separate invariant has to police.
    """

    required: dict[str, type | tuple[type, ...]]
    flags_required: dict[str, type | tuple[type, ...]] | None


_ROLE_SPEC: dict[str, RoleSpec] = {
    "implementer": RoleSpec(
        required={
            **_COMMON_REQUIRED,
            "iteration": int,
            "files_changed": list,
            "summary": str,
        },
        flags_required={
            "blocked": bool,
            "test_contract_mismatch": bool,
            "needs_test_coverage": list,
        },
    ),
    "test-writer": RoleSpec(
        required={
            **_COMMON_REQUIRED,
            "iteration": int,
            "test_files_added": list,
            "test_commands": list,
            "coverage_summary": str,
        },
        flags_required={
            "blocked": bool,
            "needs_impl_clarification": (str, type(None)),
        },
    ),
    # Reviewer is one-shot and advisory: no flag-driven branching in the
    # conductor, and reviewer-prompt.md does not emit a flags object. Keep the
    # required set narrow so a well-formed reviewer report passes validation.
    "reviewer": RoleSpec(
        required={
            "role": str,
            "phase_position": int,
            "phase_label": str,
            "findings": list,
        },
        flags_required=None,
    ),
    "ci-parity": RoleSpec(
        required={
            "role": str,
            "schema_version": int,
            "plan_id": str,
            "request_written_at_unix": (int, float),
            "status": str,
            "command_run": str,
        },
        flags_required=None,
    ),
}


def extract_last_json_block(text: str) -> str:
    """Return the body of the LAST fenced ```json block in ``text``.

    Raises SchemaError if no such block exists.
    """
    matches = _JSON_FENCE_RE.findall(text)
    if not matches:
        raise SchemaError("no fenced ```json block found in subagent output")
    return matches[-1]


def parse_report(text: str, expected_role: str) -> dict[str, Any]:
    """Extract → parse → validate the terminal JSON report.

    Raises SchemaError with a human-readable message on any failure. The
    conductor catches SchemaError, records the role + raw tail in state, sets
    ``status = "schema_error"``, and hands back to the user (no respawn).
    """
    body = extract_last_json_block(text)
    try:
        obj = json.loads(body)
    except json.JSONDecodeError as exc:
        raise SchemaError(
            f"final ```json block did not parse: {exc.msg} at line {exc.lineno}"
        ) from exc
    if not isinstance(obj, dict):
        raise SchemaError(f"report must be a JSON object, got {type(obj).__name__}")
    validate_report(obj, expected_role)
    return obj


def validate_report(obj: dict[str, Any], expected_role: str) -> None:
    """Validate ``obj`` against the schema for ``expected_role``.

    Checks presence and type of required keys, plus role match. Extra keys are
    allowed so prompts can evolve without breaking older conductors. Raises
    SchemaError on any violation.
    """
    if expected_role not in _ROLE_SPEC:
        raise SchemaError(f"unknown expected_role: {expected_role!r}")
    role_field = obj.get("role")
    if role_field != expected_role:
        raise SchemaError(
            f"role mismatch: expected {expected_role!r}, got {role_field!r}"
        )
    spec = _ROLE_SPEC[expected_role]
    for key, expected_type in spec.required.items():
        if key not in obj:
            raise SchemaError(f"missing required key: {key!r}")
        if not isinstance(obj[key], expected_type):
            actual = type(obj[key]).__name__
            want = _type_name(expected_type)
            raise SchemaError(
                f"key {key!r} has wrong type: expected {want}, got {actual}"
            )
    if expected_role == "ci-parity" and obj.get("status") not in ("passed", "failed"):
        raise SchemaError(
            f"ci-parity status must be 'passed' or 'failed', got {obj.get('status')!r}"
        )
    # Positive conditional, not an early return: a role with no flag schema
    # still falls through to any check appended below this block in the
    # future, instead of silently exempting reviewer/ci-parity from it.
    if spec.flags_required is not None:
        flags = obj["flags"]
        for fkey, fexpected in spec.flags_required.items():
            if fkey not in flags:
                raise SchemaError(f"missing required flag: {fkey!r}")
            if not isinstance(flags[fkey], fexpected):
                actual = type(flags[fkey]).__name__
                want = _type_name(fexpected)
                raise SchemaError(
                    f"flag {fkey!r} has wrong type: expected {want}, got {actual}"
                )


def _type_name(t: type | tuple[type, ...]) -> str:
    if isinstance(t, type):
        return t.__name__
    return " or ".join(x.__name__ for x in t)
