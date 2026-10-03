"""Regressions for the authored Codex worker-control contract."""

import json
import re
from pathlib import Path

import pytest

SKILL_DIR = Path(__file__).resolve().parents[1]
CLAUDE_DIR = SKILL_DIR.parents[2] / "skein" / "skills" / "conduct"


def test_authored_conduct_has_no_obsolete_worker_api():
    sources = [*SKILL_DIR.glob("*.md"), *SKILL_DIR.glob("*.py")]
    for source in sources:
        text = source.read_text()
        assert "fork_context" not in text, source.name
        assert "close_agent" not in text, source.name


def test_spawn_template_uses_supported_clean_context_arguments():
    template = (SKILL_DIR / "worker-dispatch.md").read_text()
    request = json.loads(re.search(r"```json\n(.*?)\n```", template, re.DOTALL)[1])
    assert request == {
        "task_name": "{{TASK_NAME}}",
        "fork_turns": "none",
        "reasoning_effort": "{{REASONING_EFFORT}}",
        "message": "{{FILLED_WORKER_PROMPT}}",
    }
    assert '"medium"` for implementers and test-writers' in template
    assert '"high"` for the advisory reviewer' in template


@pytest.mark.parametrize("step", [3, 6, 7])
def test_each_worker_route_explicitly_keeps_clean_context(step):
    skill = (SKILL_DIR / "SKILL.md").read_text()
    section = skill.split(f"### Step {step} —", 1)[1].split("### Step", 1)[0]
    assert 'fork_turns="none"' in section
    assert "wait_agent" in section
    assert "worker-dispatch.md" in skill
    if step == 6:
        assert 'Use the same `fork_turns="none"` lifecycle' in section


def test_availability_requires_spawn_and_wait_only():
    skill = (SKILL_DIR / "SKILL.md").read_text()
    availability = skill.split("## Delegation Availability", 1)[1].split("## ", 1)[0]
    assert "lacks `spawn_agent` or `wait_agent`" in availability
    assert "requires spawn_agent and wait_agent support." in availability
    assert "hard-stop" in availability
    gauntlet = re.split(
        r"^## ", skill.split("## Review Gauntlet Auto-Chain", 1)[1], flags=re.MULTILINE
    )[0]
    assert "lacks `spawn_agent` or `wait_agent`" in gauntlet


@pytest.mark.parametrize(
    "name",
    [
        "implementer-prompt.md",
        "test-writer-prompt.md",
        "reviewer-prompt.md",
        "ci-parity-prompt.md",
    ],
)
def test_shared_worker_prompts_retain_clean_context_and_parity(name):
    prompt = SKILL_DIR / name
    assert prompt.read_bytes() == (CLAUDE_DIR / name).read_bytes()
    assert "no prior conversation history" in prompt.read_text()
