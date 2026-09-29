"""Phase 2 CLI spike, NOT the production worker or a readiness approval.

Real Pi talks only to a deterministic loopback HTTP endpoint. These tests pin
both useful behaviour and counterexamples to the proposed isolation flags.
No model quality, hosted authentication, or provider portability is claimed.
"""

import json
import os
import signal
import subprocess
import sys
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from test_package import sandbox as sandbox  # noqa: PLC0414 — pytest fixture re-export

PROVIDER = "skein-spike"
MODEL = "fixture-model"
FLAGS = [
    "--mode",
    "json",
    "--no-session",
    "--no-skills",
    "--no-extensions",
    "--no-context-files",
    "--no-approve",
    "--no-tools",
    "--no-prompt-templates",
    "--no-themes",
    "--offline",
]


@contextmanager
def endpoint(
    *,
    status=200,
    usage=True,
    tool_call=None,
    hold=False,
    expected_key=None,
    response=None,
):
    requests = []
    arrived = threading.Event()
    release = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            requests.append(json.loads(body))
            arrived.set()
            if hold:
                release.wait(10)
            authenticated = (
                expected_key is None
                or self.headers.get("Authorization") == f"Bearer {expected_key}"
            )
            if status != 200 or not authenticated:
                self.send_response(status if authenticated else 401)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(
                    b'{"error":{"message":"fixture authentication refused"}}'
                )
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            call = tool_call if len(requests) == 1 else None
            delta = {"role": "assistant"}
            if call:
                delta["tool_calls"] = [
                    {
                        "index": 0,
                        "id": "fixture-call",
                        "type": "function",
                        "function": call,
                    }
                ]
            else:
                delta["content"] = (
                    json.dumps(response)
                    if response is not None
                    else '{"status":"ok","summary":"fixture response"}'
                )
            chunk = {
                "id": "fixture",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": MODEL,
                "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
            }
            finish = {
                **chunk,
                "choices": [
                    {
                        "index": 0,
                        "delta": {},
                        "finish_reason": "tool_calls" if call else "stop",
                    }
                ],
            }
            if usage:
                finish["usage"] = {
                    "prompt_tokens": 11,
                    "completion_tokens": 7,
                    "total_tokens": 18,
                }
            try:
                for item in (chunk, finish):
                    self.wfile.write(b"data: " + json.dumps(item).encode() + b"\n\n")
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1", requests, arrived
    finally:
        release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def configure(sandbox, url, *, credential=True):
    _, _, _, agent = sandbox
    provider = {
        "baseUrl": url,
        "api": "openai-completions",
        "models": [
            {
                "id": MODEL,
                "reasoning": False,
                "input": ["text"],
                "contextWindow": 32000,
                "maxTokens": 1000,
                "cost": {"input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0},
            }
        ],
    }
    if credential:
        provider["apiKey"] = "fixture-not-a-secret"
    (agent / "models.json").write_text(json.dumps({"providers": {PROVIDER: provider}}))
    (agent / "settings.json").write_text(
        json.dumps(
            {
                "defaultProvider": PROVIDER,
                "defaultModel": MODEL,
                "retry": {"enabled": False},
                "compaction": {"enabled": False},
            }
        )
    )


def invoke(sandbox, *, extra=(), select_model=True, env_extra=None, omit_flags=()):
    pi, env, cwd, _ = sandbox
    args = [pi, *(flag for flag in FLAGS if flag not in omit_flags)]
    if select_model:
        args += ["--provider", PROVIDER, "--model", MODEL, "--thinking", "off"]
    # Prompt is stdin data, not shell syntax, flags, or an @file argument.
    return subprocess.run(
        [*args, *extra],
        input="Return the fixture result.",
        text=True,
        env={**env, **(env_extra or {})},
        cwd=cwd,
        capture_output=True,
        timeout=20,
        check=False,
    )


def events(result):
    return [json.loads(line) for line in result.stdout.split("\n") if line.strip()]


def final_message(result):
    return [
        e["message"]
        for e in events(result)
        if e.get("type") == "message_end" and e["message"]["role"] == "assistant"
    ][-1]


def seed_ambient(sandbox):
    _, _, cwd, agent = sandbox
    markers = {}
    for label, base in (("USER", agent), ("PROJECT", cwd / ".pi")):
        base.mkdir(exist_ok=True)
        for filename in ("SYSTEM.md", "APPEND_SYSTEM.md", "AGENTS.md"):
            sentinel = f"SENTINEL_{label}_{filename.replace('.', '_')}"
            (base / filename).write_text(sentinel)
            markers[sentinel] = filename
        extension = base / "extensions" / "nested.ts"
        extension.parent.mkdir()
        # Benign stand-in for a malicious ambient extension; no real execution
        # privilege escalation or external process is needed to detect loading.
        marker = base / "extension-loaded"
        extension.write_text(
            'import { writeFileSync } from "node:fs";\n'
            f'writeFileSync({json.dumps(str(marker))}, "loaded");\n'
            'export default function(pi) { pi.registerTool({ name: "nested_dispatch",'
            ' label: "Nested", description: "Must not be offered",'
            ' parameters: { type: "object", properties: {} },'
            ' execute: async () => ({content: [{type: "text", text: "bad"}]}) }); }\n'
        )
        skill = base / "skills" / "ambient" / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            "---\nname: ambient-worker\ndescription: SENTINEL_AMBIENT_SKILL\n---\nNo.\n"
        )
    (cwd / "AGENTS.md").write_text("SENTINEL_PROJECT_ROOT_AGENTS")
    return markers


def test_json_success_cwd_tools_terminal_and_usage(sandbox):
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        result = invoke(sandbox)
    assert result.returncode == 0, result.stderr
    records = events(result)
    assert records[0]["type"] == "session"
    assert records[0]["cwd"] == str(sandbox[2])
    assert any(e["type"] == "agent_settled" for e in records)
    message = final_message(result)
    assert (message["provider"], message["model"]) == (PROVIDER, MODEL)
    assert message["stopReason"] == "stop"
    assert message["usage"]["input"] == 11
    assert message["usage"]["output"] == 7
    assert message["usage"]["cost"]["total"] > 0
    assert len(requests) == 1
    assert not requests[0].get("tools")
    assert not (sandbox[3] / "sessions").exists()


def test_isolation_flags_do_not_exclude_user_system_prompts(sandbox):
    """Counterexample: green regression test documents a BLOCKED readiness gate."""
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        markers = seed_ambient(sandbox)
        result = invoke(sandbox)
    assert result.returncode == 0, result.stderr
    sent = json.dumps(requests)
    for marker in markers:
        if marker.startswith("SENTINEL_USER_") and "AGENTS" not in marker:
            assert marker in sent  # User SYSTEM and APPEND_SYSTEM escape the flags.
        else:
            assert marker not in sent
    assert "SENTINEL_PROJECT_ROOT_AGENTS" not in sent
    assert "SENTINEL_AMBIENT_SKILL" not in sent
    assert "nested_dispatch" not in sent
    assert not (sandbox[3] / "extension-loaded").exists()
    assert not (sandbox[2] / ".pi/extension-loaded").exists()


def test_ambient_extension_fixture_is_loadable_without_disable_flag(sandbox):
    """Positive control: the negative isolation test isn't using a broken fixture."""
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        seed_ambient(sandbox)
        result = invoke(
            sandbox,
            omit_flags=("--no-extensions",),
            extra=("--tools", "nested_dispatch"),
        )
    assert result.returncode == 0, result.stderr
    assert (sandbox[3] / "extension-loaded").read_text() == "loaded"
    assert not (sandbox[2] / ".pi/extension-loaded").exists()
    assert [t["function"]["name"] for t in requests[0]["tools"]] == ["nested_dispatch"]


def test_explicit_system_prompts_close_prompt_leak_only(sandbox):
    with endpoint() as (url, requests, _):
        configure(sandbox, url)
        seed_ambient(sandbox)
        result = invoke(
            sandbox,
            extra=(
                "--system-prompt",
                "CURATED_WORKER_ROLE",
                "--append-system-prompt",
                "CURATED_PROJECT_RULES",
            ),
        )
    assert result.returncode == 0, result.stderr
    sent = json.dumps(requests)
    assert "SENTINEL_" not in sent
    assert "CURATED_WORKER_ROLE" in sent
    assert "CURATED_PROJECT_RULES" in sent


def test_disabled_resources_still_resolve_user_packages(sandbox):
    """Resource-disable flags are not a package-installer boundary."""
    _, _, _, agent = sandbox
    marker = agent / "package-manager-ran"
    fake_npm = agent / "fixture-npm.py"
    fake_npm.write_text(
        "from pathlib import Path\nimport sys\n"
        f"Path({str(marker)!r}).write_text('invoked')\n"
        "sys.exit(1)\n"
    )
    with endpoint() as (url, _, _):
        configure(sandbox, url)
        settings_path = agent / "settings.json"
        settings = json.loads(settings_path.read_text())
        settings.update(
            {
                "packages": ["npm:@skein-spike/unavailable@0.0.0"],
                "npmCommand": [sys.executable, str(fake_npm)],
            }
        )
        settings_path.write_text(json.dumps(settings))
        invoke(
            sandbox,
            extra=(
                "--system-prompt",
                "CURATED_WORKER_ROLE",
                "--append-system-prompt",
                "CURATED_PROJECT_RULES",
            ),
        )
    assert marker.exists()  # No network: fixture npm only writes this marker.


def test_json_auth_error_can_exit_zero(sandbox):
    with endpoint(status=401) as (url, requests, _):
        configure(sandbox, url)
        result = invoke(sandbox)
    assert requests
    assert result.returncode == 0
    assert final_message(result)["stopReason"] == "error"
    assert any(e["type"] == "agent_settled" for e in events(result))


def test_missing_credentials_never_reach_endpoint(sandbox):
    with endpoint() as (url, requests, _):
        configure(sandbox, url, credential=False)
        result = invoke(sandbox)
    assert not requests
    assert result.returncode != 0 or final_message(result)["stopReason"] == "error"


def test_missing_usage_is_synthesized_as_zero_by_cli(sandbox):
    with endpoint(usage=False) as (url, _, _):
        configure(sandbox, url)
        result = invoke(sandbox)
    assert result.returncode == 0, result.stderr
    message = final_message(result)
    assert message["stopReason"] == "stop"
    assert message["usage"]["input"] == 0
    assert message["usage"]["output"] == 0
    assert message["usage"]["cost"]["total"] == 0
    # A dispatcher must report unknown here, not a measured free invocation.


def test_hanging_cli_can_be_terminated_as_a_process_group(sandbox):
    pi, env, cwd, _ = sandbox
    with endpoint(hold=True) as (url, _, arrived):
        configure(sandbox, url)
        process = subprocess.Popen(
            [pi, *FLAGS, "--provider", PROVIDER, "--model", MODEL, "fixture"],
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            assert arrived.wait(10), "Pi did not reach the hanging fixture"
            os.killpg(process.pid, signal.SIGTERM)
            stdout, _ = process.communicate(timeout=5)
            assert process.returncode != 0
            assert b'"type":"agent_settled"' not in stdout
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
