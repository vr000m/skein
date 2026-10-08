"""Regression contracts for the runtime request interpreted from gauntlet prompts."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = ROOT / "plugins/skein-codex/skills/review-gauntlet"
SKILL = (SKILL_DIR / "SKILL.md").read_text()
DISPATCH = (SKILL_DIR / "worker-dispatch.md").read_text()


def test_request_preserves_prompt_as_data_and_uses_supported_arguments():
    template = json.loads(re.search(r"```json\n(.*?)\n```", DISPATCH, re.DOTALL)[1])
    prompt = 'Finding: "quoted"\nLiteral `$(touch unwanted)` stays data.'
    request = {
        key: {
            "{{TASK_NAME}}": "fixer_1",
            "{{REASONING_EFFORT}}": "medium",
            "{{FILLED_FIXER_PROMPT}}": prompt,
        }.get(value, value)
        for key, value in template.items()
    }
    assert set(request) == {"task_name", "fork_turns", "reasoning_effort", "message"}
    assert request["fork_turns"] == "none"
    assert json.loads(json.dumps(request))["message"] == prompt
    assert request["reasoning_effort"] == "medium"
    assert "model" not in request


def test_all_fixer_routes_share_one_dispatch_contract():
    delegation = SKILL.split("## Delegation Pattern", 1)[1].split(
        "## Gate Sequence", 1
    )[0]
    assert "Every fixer dispatch" in delegation
    for route in ("quick-mode fixes", "resumed batches", "retries"):
        assert route in delegation
    assert "[worker-dispatch.md](worker-dispatch.md)" in delegation
    assert 'fork_turns="none"' in delegation
    assert delegation.count("reasoning_effort=medium") == 1
    assert "when supported" in delegation


def test_obsolete_arguments_and_close_requirement_do_not_return():
    for text in (SKILL, DISPATCH):
        assert "fork_context" not in text
        assert "close_agent" not in text
    assert "If `spawn_agent` or `wait_agent` is unavailable" in SKILL
    assert "Do not silently degrade into main-session fixing" in SKILL


def test_mailbox_and_nonterminal_output_cannot_advance_the_ledger():
    assert "not the fixer report" in SKILL
    assert "final message without terminal status is still incomplete" in SKILL
    assert "before validating the existing report schema" in SKILL
    assert "or advancing the convergence ledger" in SKILL
    assert "without counting the batch as fixed" in SKILL


def test_failed_dispatch_drains_workers_and_preserves_original_error():
    assert "including a capacity error" in SKILL
    assert "drain any already-started workers to terminal status" in SKILL
    assert "before handing back the actual dispatch error" in SKILL
    assert "Keep existing ledger state" in SKILL
    assert "retries use fresh workers" in SKILL
    assert "never reuse an earlier conversation" in SKILL


def test_terminal_errors_and_malformed_reports_are_handbacks():
    assert "terminal failure or malformed output hands back the actual error" in (
        SKILL.lower()
    )
    assert "no additional worker lifecycle operation" in SKILL.lower()


def test_existing_live_verification_and_gate_accounting_are_preserved():
    assert "Do not report a round's outcome from the fixer subagent's return" in SKILL
    assert "known permanent capability gaps do not count" in SKILL
    assert "--claimed-keys" in SKILL
    assert "Every gate-output step goes through" in SKILL
