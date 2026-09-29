"""Real Pi RPC test for the trusted extension → host → private child route."""

import json
import os
import selectors
import shutil
import subprocess
import sys
import time
from pathlib import Path

from test_dispatcher import RESULT
from test_package import ROOT, package_fixture, run
from test_package import sandbox as sandbox  # noqa: PLC0414 — pytest fixture re-export
from test_worker import MODEL, PROVIDER, configure, endpoint

EXTENSION = ROOT / "plugins/skein-pi/extension.ts"


def rpc_worker(sandbox, *, approve, explicit_extension=True):
    pi, env, cwd, _ = sandbox
    env = {**env, "SKEIN_PI_PYTHON": str(Path(sys.executable).resolve())}
    args = [
        pi,
        "--mode",
        "rpc",
        "--no-session",
        "--no-skills",
        "--no-context-files",
        "--no-approve",
        "--tools",
        "skein_worker",
        "--no-prompt-templates",
        "--no-themes",
        "--offline",
        "--provider",
        PROVIDER,
        "--model",
        MODEL,
        "--thinking",
        "off",
    ]
    if explicit_extension:
        args[4:4] = ["--no-extensions", "--extension", str(EXTENSION)]
    process = subprocess.Popen(
        args,
        env=env,
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    selector.register(process.stderr, selectors.EVENT_READ)
    process.stdin.write(
        json.dumps(
            {
                "id": "prompt",
                "type": "prompt",
                "message": "Delegate this exact bounded fixture task.",
            }
        ).encode()
        + b"\n"
    )
    process.stdin.flush()
    stdout = bytearray()
    stderr = bytearray()
    records = []
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            while b"\n" in stdout:
                line, _, rest = stdout.partition(b"\n")
                stdout = bytearray(rest)
                record = json.loads(line)
                records.append(record)
                if record.get("type") == "extension_ui_request":
                    assert record["method"] == "confirm"
                    assert "fixture-not-a-secret" not in json.dumps(record)
                    process.stdin.write(
                        json.dumps(
                            {
                                "type": "extension_ui_response",
                                "id": record["id"],
                                "confirmed": approve,
                            }
                        ).encode()
                        + b"\n"
                    )
                    process.stdin.flush()
                if record.get("type") == "agent_settled":
                    return records, stderr.decode(errors="replace")
            for key, _ in selector.select(timeout=0.2):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    continue
                if key.fileobj is process.stderr:
                    stderr.extend(chunk)
                else:
                    stdout.extend(chunk)
        raise AssertionError(f"RPC timeout: {stderr.decode(errors='replace')}")
    finally:
        selector.close()
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()


def tool_results(records):
    return [record for record in records if record.get("type") == "tool_execution_end"]


def test_extension_approved_worker_end_to_end(sandbox, tmp_path):
    worker_prompt = 'Return the "validated" fixture\nresult.'
    call = {
        "name": "skein_worker",
        "arguments": json.dumps({"role": "judgment", "prompt": worker_prompt}),
    }
    with endpoint(
        tool_call=call,
        response=RESULT,
        expected_key="fixture-not-a-secret",
    ) as (url, requests, _):
        configure(sandbox, url)
        package = package_fixture(tmp_path / "installed package with spaces")
        run([sandbox[0], "install", str(package)], sandbox[1], sandbox[2])
        records, stderr = rpc_worker(sandbox, approve=True, explicit_extension=False)
    assert stderr == ""
    assert len(requests) == 3
    confirmation = next(
        record for record in records if record.get("type") == "extension_ui_request"
    )
    assert "Role: judgment" in confirmation["message"]
    assert json.dumps(worker_prompt) in confirmation["message"]
    assert f"Model: {PROVIDER}/{MODEL}" in confirmation["message"]
    assert f"Endpoint: {url}" in confirmation["message"]
    assert requests[0]["tools"][0]["function"]["name"] == "skein_worker"
    assert not requests[1].get("tools")  # Private child is no-tools.
    assert requests[1]["model"] == MODEL
    results = tool_results(records)
    assert len(results) == 1 and not results[0]["isError"]
    text = results[0]["result"]["content"][0]["text"]
    envelope = json.loads(text)
    assert envelope["status"] == "completed"
    assert envelope["result"] == RESULT
    assert "fixture-not-a-secret" not in json.dumps(records)
    state = sandbox[2] / ".skein-pi-attempts"
    files = list(state.glob("*.json"))
    assert len(files) == 1
    assert json.loads(files[0].read_text()) == envelope
    shutil.rmtree(state)


def test_extension_declined_worker_never_starts_child(sandbox):
    call = {
        "name": "skein_worker",
        "arguments": json.dumps({"role": "factual", "prompt": "Do not run."}),
    }
    with endpoint(tool_call=call, response=RESULT) as (url, requests, _):
        configure(sandbox, url)
        records, _ = rpc_worker(sandbox, approve=False)
    # Parent initial call + its follow-up after the declined tool result; no child call.
    assert len(requests) == 2
    results = tool_results(records)
    assert len(results) == 1 and results[0]["isError"]
    content = results[0]["result"]["content"][0]["text"]
    assert "operator_declined" in content
    assert not (sandbox[2] / ".skein-pi-attempts").exists()
