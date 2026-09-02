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
from typing import Any

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

_ROLE_REQUIRED: dict[str, dict[str, type | tuple[type, ...]]] = {
    "implementer": {
        **_COMMON_REQUIRED,
        "iteration": int,
        "files_changed": list,
        "summary": str,
    },
    "test-writer": {
        **_COMMON_REQUIRED,
        "iteration": int,
        "test_files_added": list,
        "test_commands": list,
        "coverage_summary": str,
    },
    # Reviewer is one-shot and advisory: no flag-driven branching in the
    # conductor, and reviewer-prompt.md does not emit a flags object. Keep the
    # required set narrow so a well-formed reviewer report passes validation.
    "reviewer": {
        "role": str,
        "phase_position": int,
        "phase_label": str,
        "findings": list,
    },
    # CI-parity worker (Phase 3 end-of-plan gate). The conductor compares
    # ``plan_id`` and ``request_written_at_unix`` against the request stored
    # in state to detect stale result files; mismatched values are handled at
    # the preflight layer, not here. Optional fields (``duration_seconds``,
    # ``last_2000_bytes_of_output``, ``summary``) are accepted but not
    # enforced — the conductor cares structurally about ``status``.
    "ci-parity": {
        "role": str,
        "schema_version": int,
        "plan_id": str,
        "request_written_at_unix": (int, float),
        "status": str,
        "command_run": str,
    },
}

# Explicit per-role flag membership, instead of leaving "does this role emit
# flags" to be inferred from which roles happen to appear in
# _ROLE_FLAGS_REQUIRED. Reviewer and ci-parity are one-shot/advisory roles
# with no flag-driven branching in the conductor; adding a new no-flags role
# means adding `False` here, not just omitting it elsewhere and hoping the
# omission reads as intentional.
_ROLE_HAS_FLAGS: dict[str, bool] = {
    "implementer": True,
    "test-writer": True,
    "reviewer": False,
    "ci-parity": False,
}

# Role-specific flag substructure. Enforced only when the role emits flags
# (implementer + test-writer). The conductor branches on these keys, so a
# missing key is a real runtime failure — not an evolving-prompt edge case.
_ROLE_FLAGS_REQUIRED: dict[str, dict[str, type | tuple[type, ...]]] = {
    "implementer": {
        "blocked": bool,
        "test_contract_mismatch": bool,
        "needs_test_coverage": list,
    },
    "test-writer": {
        "blocked": bool,
        "needs_impl_clarification": (str, type(None)),
    },
}


# Plain `if`/`raise` rather than `assert`: `assert` is compiled out entirely
# under `python -O`/`PYTHONOPTIMIZE=1`, which would silently defeat both
# invariants below. Checked at import time, so drift is caught at test
# collection, not the first time an affected role is actually validated.
if set(_ROLE_REQUIRED) != set(_ROLE_HAS_FLAGS):
    raise AssertionError(
        "_ROLE_REQUIRED and _ROLE_HAS_FLAGS have drifted: every role must have "
        "an explicit has_flags entry."
    )
if set(_ROLE_FLAGS_REQUIRED) != {r for r, has in _ROLE_HAS_FLAGS.items() if has}:
    raise AssertionError(
        "_ROLE_FLAGS_REQUIRED and _ROLE_HAS_FLAGS have drifted: every role marked "
        "has_flags=True must have a flag schema, and vice versa."
    )


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
    if expected_role not in _ROLE_REQUIRED:
        raise SchemaError(f"unknown expected_role: {expected_role!r}")
    if expected_role not in _ROLE_HAS_FLAGS:
        raise SchemaError(f"role {expected_role!r} missing from _ROLE_HAS_FLAGS")
    role_field = obj.get("role")
    if role_field != expected_role:
        raise SchemaError(
            f"role mismatch: expected {expected_role!r}, got {role_field!r}"
        )
    schema = _ROLE_REQUIRED[expected_role]
    for key, expected_type in schema.items():
        if key not in obj:
            raise SchemaError(f"missing required key: {key!r}")
        if not isinstance(obj[key], expected_type):
            actual = type(obj[key]).__name__
            want = _type_name(expected_type)
            raise SchemaError(
                f"key {key!r} has wrong type: expected {want}, got {actual}"
            )
    # CI-parity has an enum constraint on `status`.
    if expected_role == "ci-parity":
        status_field = obj.get("status")
        if status_field not in ("passed", "failed"):
            raise SchemaError(
                f"ci-parity status must be 'passed' or 'failed', got {status_field!r}"
            )
    if not _ROLE_HAS_FLAGS[expected_role]:
        return
    # Guaranteed present by the module-level invariant check above (every
    # has_flags=True role has a _ROLE_FLAGS_REQUIRED entry) — direct index,
    # not .get(), since a None here would mean that invariant broke.
    flag_schema = _ROLE_FLAGS_REQUIRED[expected_role]
    flags = obj["flags"]
    for fkey, fexpected in flag_schema.items():
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
