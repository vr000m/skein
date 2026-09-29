"""Real CLI identity spike; observations, not a shipped model-policy layer."""

import json

from test_package import sandbox as sandbox  # noqa: PLC0414 — pytest fixture re-export
from test_worker import MODEL, PROVIDER, configure, endpoint, final_message, invoke


def test_shell_environment_is_not_a_child_model_selection(sandbox):
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        result = invoke(
            sandbox,
            select_model=False,
            env_extra={
                "PI_PROVIDER": "stale-parent-provider",
                "PI_MODEL": "stale-parent-model",
                "PI_REASONING_LEVEL": "high",
            },
        )
    assert result.returncode == 0, result.stderr
    message = final_message(result)
    assert (message["provider"], message["model"]) == (PROVIDER, MODEL)
    assert requests[0]["model"] == MODEL
    # A future dispatcher must reject absent approved identity before launch;
    # the CLI silently selecting its configured default is not that guard.


def test_absent_parent_identity_also_uses_cli_default(sandbox):
    assert not any(key in sandbox[1] for key in ("PI_PROVIDER", "PI_MODEL"))
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        result = invoke(sandbox, select_model=False)
    assert result.returncode == 0, result.stderr
    assert requests[0]["model"] == MODEL


def test_model_pattern_is_not_an_exact_identity_pin(sandbox):
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        result = invoke(sandbox, extra=("--model", "fixture"))
    assert result.returncode == 0, result.stderr
    assert requests[0]["model"] == MODEL
    assert final_message(result)["model"] == MODEL


def test_unknown_provider_does_not_call_endpoint(sandbox):
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        result = invoke(sandbox, extra=("--provider", "skein-does-not-exist"))
    assert result.returncode != 0
    assert not requests


def test_missing_model_id_can_be_forwarded_as_custom_model(sandbox):
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        result = invoke(sandbox, extra=("--model", "absent-model"))
    # CLI fallback may forward an unknown ID rather than proving availability.
    # A readiness layer must validate the exact model against an approved catalog.
    assert result.returncode == 0, result.stderr
    assert requests[0]["model"] == "absent-model"
    assert final_message(result)["model"] == "absent-model"


def test_llm_bash_replaces_inherited_session_identity(sandbox):
    # Only this controlled probe enables bash; the deterministic endpoint asks
    # for a benign print of three NON-SECRET variables, not the environment.
    call = {
        "name": "bash",
        "arguments": json.dumps(
            {
                "command": (
                    "printf 'IDENTITY=%s/%s/%s' "
                    '"$PI_PROVIDER" "$PI_MODEL" "$PI_REASONING_LEVEL"'
                )
            }
        ),
    }
    with endpoint(tool_call=call) as (url, requests, _):
        configure(sandbox, url)
        result = invoke(
            sandbox,
            extra=("--tools", "bash"),
            env_extra={
                "PI_PROVIDER": "stale",
                "PI_MODEL": "stale",
                "PI_REASONING_LEVEL": "high",
            },
        )
    assert result.returncode == 0, result.stderr
    assert len(requests) == 2
    assert [t["function"]["name"] for t in requests[0]["tools"]] == ["bash"]
    tool_messages = [m for m in requests[1]["messages"] if m["role"] == "tool"]
    assert len(tool_messages) == 1
    assert f"IDENTITY={PROVIDER}/{MODEL}/off" in tool_messages[0]["content"]
    # This proves Pi's injection at the tool boundary, not provenance of arbitrary
    # env strings presented to a future standalone dispatcher by another shell.
