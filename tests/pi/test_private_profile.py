"""Retest startup isolation with private profiles; no production dispatcher."""

import importlib.util
import json
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest
from test_package import ROOT
from test_package import sandbox as sandbox  # noqa: PLC0414 — pytest fixture re-export
from test_worker import (
    MODEL,
    PROVIDER,
    configure,
    endpoint,
    events,
    final_message,
    invoke,
    seed_ambient,
)


@pytest.fixture(scope="module")
def profile_module():
    path = ROOT / "plugins/skein-pi/lib/private_profile.py"
    spec = importlib.util.spec_from_file_location("skein_pi_private_profile", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def approval(url):
    # Test operator's explicit selection, not derived from PI_* or task text.
    return {
        "approved": True,
        "provider": PROVIDER,
        "model": MODEL,
        "api": "openai-completions",
        "base_url": url,
        "thinking": "off",
        "context_window": 32000,
        "max_tokens": 1000,
        "credential_type": "api_key",
    }


def profile_args(sandbox, url, tmp_path):
    node = shutil.which("node")
    assert node, "Pi profile spike requires an explicit Node executable"
    return {
        "approval": approval(url),
        "credential": "approved-fixture-not-a-secret",
        "node": Path(node).resolve(),
        "pi_cli": Path(sandbox[0]).resolve(),
        "cwd": sandbox[2],
        "temp_root": tmp_path,
        "system_prompt": "CURATED_PRIVATE_ROLE",
        "project_rules": "CURATED_PRIVATE_RULES",
    }


def call(profile, prompt="Return the fixture result."):
    return subprocess.run(
        profile.argv,
        env=profile.env,
        cwd=profile.cwd,
        input=prompt,
        text=True,
        capture_output=True,
        check=False,
        timeout=20,
    )


def snapshot(directory):
    return {
        str(path.relative_to(directory)): path.read_bytes()
        for path in directory.rglob("*")
        if path.is_file()
    }


def contaminate(sandbox):
    _, _, cwd, agent = sandbox
    seed_ambient(sandbox)
    marker_script = agent / "ambient-command.py"
    command_marker = agent / "ambient-command-ran"
    marker_script.write_text(
        "from pathlib import Path\n"
        f"Path({str(command_marker)!r}).write_text('ran')\n"
        "print('ambient-fixture-key')\n"
    )
    # Shell syntax here is controlled test fixture data, never a launch strategy.
    import shlex

    secret_command = f"!{shlex.quote(sys.executable)} {shlex.quote(str(marker_script))}"
    settings = {
        "packages": ["npm:@skein-spike/unavailable@0.0.0"],
        "npmCommand": [sys.executable, str(marker_script)],
        "defaultProvider": "wrong-provider",
        "defaultModel": "wrong-model",
        "sessionDir": str(cwd / "ambient-sessions"),
        "defaultTools": ["bash"],
        "defaultProjectTrust": "always",
    }
    for base in (agent, cwd / ".pi"):
        (base / "settings.json").write_text(json.dumps(settings))
    (agent / "auth.json").write_text(
        json.dumps(
            {
                PROVIDER: {"type": "api_key", "key": secret_command},
                "unapproved-provider": {"type": "api_key", "key": "other-fixture-key"},
            }
        )
    )
    models = json.loads((agent / "models.json").read_text())
    models["providers"][PROVIDER]["apiKey"] = secret_command
    (agent / "models.json").write_text(json.dumps(models))
    # Additional conventional user and project skill roots must remain absent.
    for base in (Path(sandbox[1]["HOME"]), cwd):
        skill = base / ".agents/skills/ambient/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            "---\nname: secret-ambient\ndescription: SENTINEL_AGENTS_SKILL\n---\nNo.\n"
        )
    return command_marker


def test_private_profile_excludes_contaminated_parent_and_project(
    sandbox,
    tmp_path,
    monkeypatch,
    profile_module,
):
    with endpoint(expected_key="approved-fixture-not-a-secret") as (url, requests, _):
        configure(sandbox, url)
        marker = contaminate(sandbox)
        args = profile_args(sandbox, url, tmp_path)
        project_before = snapshot(sandbox[2])
        preload = sandbox[3] / "preload.cjs"
        preload_marker = sandbox[3] / "node-preload-ran"
        preload.write_text(
            f"require('node:fs').writeFileSync({json.dumps(str(preload_marker))}, 'ran');"
        )
        parent_before = snapshot(sandbox[3])
        poison = {
            "HOME": sandbox[1]["HOME"],
            "PI_CODING_AGENT_DIR": str(sandbox[3]),
            "PI_PACKAGE_DIR": str(sandbox[3]),
            "PI_CODING_AGENT_SESSION_DIR": str(sandbox[2] / "ambient-sessions"),
            "PI_PROVIDER": "stale",
            "PI_MODEL": "stale",
            "PI_REASONING_LEVEL": "high",
            "NODE_OPTIONS": f'--require "{preload}"',
            "NODE_PATH": str(sandbox[3]),
            "OPENAI_API_KEY": "ambient-fixture-key",
            "AWS_PROFILE": "ambient-profile",
            "HTTP_PROXY": "http://127.0.0.1:1",
            "HTTPS_PROXY": "http://127.0.0.1:1",
            "PATH": str(sandbox[3]),
        }
        for key, value in poison.items():
            monkeypatch.setenv(key, value)
        with profile_module.private_profile(**args) as profile:
            root = profile.root
            assert profile.env["HOME"] != poison["HOME"]
            assert not set(poison).difference(
                {"HOME", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "PATH"}
            ) & set(profile.env)
            assert profile.cwd == sandbox[2].resolve()
            assert profile.argv[:2] == (str(args["node"]), str(args["pi_cli"]))
            result = call(profile)
            assert result.returncode == 0, result.stderr
            message = final_message(result)
            assert message["stopReason"] == "stop"
            assert (message["provider"], message["model"]) == (PROVIDER, MODEL)
            assert any(e["type"] == "agent_settled" for e in events(result))
            assert len(requests) == 1
            sent = json.dumps(requests)
            assert "SENTINEL_" not in sent
            assert "CURATED_PRIVATE_ROLE" in sent and "CURATED_PRIVATE_RULES" in sent
            assert not requests[0].get("tools")
            assert not (root / "sessions").exists()
            assert args["credential"] not in result.stdout + result.stderr + repr(
                profile
            )
            assert not marker.exists()
            assert not preload_marker.exists()
        assert not root.exists()
        assert snapshot(sandbox[3]) == parent_before
        assert snapshot(sandbox[2]) == project_before


def test_parent_credential_command_positive_control(sandbox):
    with endpoint() as (url, _, _):
        configure(sandbox, url)
        marker = contaminate(sandbox)
        # Keep just the credential-command path for this control: package
        # installation is covered separately by the original CLI spike.
        (sandbox[3] / "settings.json").write_text(
            json.dumps({"retry": {"enabled": False}})
        )
        result = invoke(sandbox)
    assert result.returncode == 0, result.stderr
    assert marker.read_text() == "ran"


def test_model_cannot_invoke_a_hallucinated_shell_tool(
    sandbox, tmp_path, profile_module
):
    target = sandbox[2] / "nested-dispatch-would-run"
    # A provider may return tool calls even when none were offered. Pi must
    # reject them rather than let an invented tool run a nested process.
    call_request = {
        "name": "bash",
        "arguments": json.dumps({"command": f"touch '{target}'"}),
    }
    with (
        endpoint(tool_call=call_request) as (url, requests, _),
        profile_module.private_profile(
            **profile_args(sandbox, url, tmp_path)
        ) as profile,
    ):
        result = call(profile)
    assert result.returncode == 0, result.stderr
    assert not target.exists()
    assert len(requests) == 2
    assert all(not request.get("tools") for request in requests)
    results = [
        event for event in events(result) if event["type"] == "tool_execution_end"
    ]
    assert results and all(event["isError"] for event in results)


def test_private_profile_permissions_single_credential_and_cleanup(
    sandbox, tmp_path, profile_module
):
    args = profile_args(sandbox, "http://127.0.0.1:1/v1", tmp_path)
    with profile_module.private_profile(**args) as profile:
        root = profile.root
        assert stat.S_IMODE(root.stat().st_mode) == 0o700
        for path in root.rglob("*"):
            assert stat.S_IMODE(path.stat().st_mode) == (
                0o700 if path.is_dir() else 0o600
            )
        auth_path = profile.agent_dir / "auth.json"
        assert json.loads(auth_path.read_text()) == {
            PROVIDER: {"type": "api_key", "key": args["credential"]}
        }
        for path in root.rglob("*"):
            if path.is_file() and path != auth_path:
                assert args["credential"] not in path.read_text()
        assert args["credential"] not in repr(profile)
        assert set(
            json.loads((profile.agent_dir / "models.json").read_text())["providers"]
        ) == {PROVIDER}
    assert not root.exists()


def test_profile_cleanup_on_caller_exception(sandbox, tmp_path, profile_module):
    with (
        pytest.raises(RuntimeError, match="fixture failure"),
        profile_module.private_profile(
            **profile_args(sandbox, "http://127.0.0.1:1/v1", tmp_path)
        ) as profile,
    ):
        root = profile.root
        raise RuntimeError("fixture failure")
    assert not root.exists()


def test_profiles_do_not_share_mutable_state(sandbox, tmp_path, profile_module):
    args = profile_args(sandbox, "http://127.0.0.1:1/v1", tmp_path)
    with profile_module.private_profile(**args) as first:
        (first.agent_dir / "APPEND_SYSTEM.md").write_text("contaminated first attempt")
        with profile_module.private_profile(**args) as second:
            assert first.root != second.root
            assert not (second.agent_dir / "APPEND_SYSTEM.md").exists()
            assert first.env["HOME"] != second.env["HOME"]


@pytest.mark.parametrize(
    "change,diagnostic",
    [
        ({"approved": False}, "operator_approval_required"),
        ({"approved": "true"}, "operator_approval_required"),
        ({"credential_type": "oauth"}, "credential_type_unsupported"),
        ({"credential_type": "ambient"}, "credential_type_unsupported"),
        ({"api": "extension-backed"}, "provider_lane_unsupported"),
        ({"thinking": "high"}, "provider_lane_unsupported"),
        ({"model": "*"}, "identity_invalid"),
        ({"model": "fixture:high"}, "identity_invalid"),
        ({"provider": ""}, "identity_invalid"),
        ({"base_url": "!execute-me"}, "endpoint_invalid"),
        ({"base_url": "https://user:secret@example.invalid/v1"}, "endpoint_invalid"),
        ({"base_url": "https://example.invalid/v1?api_key=secret"}, "endpoint_invalid"),
        ({"base_url": "http://example.invalid/v1"}, "endpoint_invalid"),
        ({"context_window": True}, "model_limits_invalid"),
        ({"max_tokens": 9999999}, "model_limits_invalid"),
        ({"headers": {"Authorization": "secret"}}, "approval_schema_invalid"),
    ],
)
def test_invalid_approval_fails_before_profile_creation(
    profile_module, sandbox, tmp_path, change, diagnostic
):
    args = profile_args(sandbox, "http://127.0.0.1:1/v1", tmp_path)
    args["approval"].update(change)
    before = set(tmp_path.iterdir())
    with (
        pytest.raises(profile_module.ProfileError) as error,
        profile_module.private_profile(**args),
    ):
        pytest.fail("invalid approval yielded a profile")
    assert str(error.value) == diagnostic
    assert set(tmp_path.iterdir()) == before


@pytest.mark.parametrize(
    "credential",
    [None, "", "!touch /tmp/not-run", "$API_KEY", "${API_KEY}", " key", "key\n"],
)
def test_rejects_missing_or_executable_credentials(profile_module, credential):
    with pytest.raises(
        profile_module.ProfileError, match="^literal_credential_required$"
    ):
        profile_module.validate_approval(
            approval("https://example.invalid/v1"), credential
        )


def test_missing_identity_cannot_fall_back_to_environment(profile_module, monkeypatch):
    monkeypatch.setenv("PI_PROVIDER", PROVIDER)
    monkeypatch.setenv("PI_MODEL", MODEL)
    for record in (None, {}, {"approved": True}):
        with pytest.raises(
            profile_module.ProfileError, match="^approval_schema_invalid$"
        ):
            profile_module.validate_approval(record, "fixture-key")


@pytest.mark.parametrize("tools", [("bash",), ("read",), ("nested_dispatch",)])
def test_untested_tool_lanes_fail_closed(sandbox, tmp_path, profile_module, tools):
    args = profile_args(sandbox, "http://127.0.0.1:1/v1", tmp_path)
    with (
        pytest.raises(profile_module.ProfileError, match="^tools_not_yet_supported$"),
        profile_module.private_profile(**args, tools=tools),
    ):
        pytest.fail("untested tool lane yielded a profile")


def test_private_profile_auth_refusal_does_not_select_another_model(
    sandbox, tmp_path, profile_module
):
    with endpoint(status=401) as (url, requests, _):
        args = profile_args(sandbox, url, tmp_path)
        with profile_module.private_profile(**args) as profile:
            result = call(profile)
    assert len(requests) == 1
    assert requests[0]["model"] == MODEL
    assert final_message(result)["stopReason"] == "error"
    assert args["credential"] not in result.stdout + result.stderr
