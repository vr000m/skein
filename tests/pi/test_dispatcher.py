"""Dispatcher contracts: real-Pi loopback tests plus adversarial process fixtures."""

import importlib
import json
import stat
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from test_package import ROOT
from test_package import sandbox as sandbox  # noqa: PLC0414 — pytest fixture re-export
from test_private_profile import profile_args
from test_worker import endpoint

RESULT = {
    "schema_version": 1,
    "status": "ok",
    "summary": "Verified fixture",
    "findings": [],
    "artifact": None,
}
TASK = {
    "task_id": "review",
    "attempt": 1,
    "role": "judgment",
    "prompt": "Review the supplied facts.",
}


@pytest.fixture(scope="module")
def dispatch_module():
    sys.path.insert(0, str(ROOT / "plugins/skein-pi/lib"))
    try:
        return importlib.import_module("dispatcher")
    finally:
        sys.path.pop(0)


@pytest.fixture
def make_dispatcher(sandbox, tmp_path, dispatch_module):
    def make(url="http://127.0.0.1:1/v1", **overrides):
        args = profile_args(sandbox, url, tmp_path)
        selected = dispatch_module.approve_selection(
            args.pop("approval"), args.pop("credential"), confirm=lambda _summary: True
        )
        args.pop("system_prompt")
        profiles = tmp_path / "profiles"
        profiles.mkdir(exist_ok=True)
        args.update(temp_root=profiles, state_root=tmp_path / "attempts", timeout_s=5)
        args.update(overrides)
        return dispatch_module.Dispatcher(selected=selected, **args)

    return make


def fake_cli(tmp_path, mode="ok"):
    """Trusted deterministic executable, not a model or a shipped runtime."""
    script = tmp_path / f"fake-cli-{mode}.py"
    script.write_text(
        "import json, os, signal, sys, time\nfrom pathlib import Path\n"
        f"mode = {mode!r}\nroot = Path({str(tmp_path)!r})\n"
        f"result = {RESULT!r}\n"
        "args = sys.argv\n"
        "def arg(name): return args[args.index(name)+1]\n"
        "profile = Path(arg('--system-prompt')).parent\n"
        "key = json.loads((profile/'agent/auth.json').read_text())[arg('--provider')]['key']\n"
        "if mode == 'early_stdin':\n"
        "    sys.stdin.close(); payload = ''\n"
        "else: payload = sys.stdin.read()\n"
        "(root/'received-prompt').write_text(payload)\n"
        "if mode == 'malformed': print('{broken'); sys.exit(0)\n"
        "if mode == 'bad_utf8': sys.stdout.buffer.write(b'\\xff\\n'); sys.exit(0)\n"
        "if mode == 'flood_stdout': sys.stdout.write('x'*1000000); sys.stdout.flush(); time.sleep(30)\n"
        "if mode == 'flood_stderr': sys.stderr.write('x'*1000000); sys.stderr.flush(); time.sleep(30)\n"
        "if mode == 'stderr_key': print(key, file=sys.stderr)\n"
        "if mode in ('hang', 'child_hang'):\n"
        "    (root/'started').write_text('yes')\n"
        "    if mode == 'child_hang' and os.fork() == 0:\n"
        "        signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "        while True:\n"
        "            with (root/'heartbeat').open('a') as stream: stream.write('x')\n"
        "            time.sleep(0.02)\n"
        "    time.sleep(30)\n"
        "if mode == 'concurrency':\n"
        "    with (root/'timeline').open('a') as stream: stream.write(json.dumps([time.monotonic(),1])+'\\n')\n"
        "    time.sleep(0.2)\n"
        "    with (root/'timeline').open('a') as stream: stream.write(json.dumps([time.monotonic(),-1])+'\\n')\n"
        "if mode == 'secret_result': result['summary'] = key\n"
        "if mode == 'bad_schema': result['extra'] = 'not allowed'\n"
        "usage = {'input':11,'output':7,'cacheRead':0,'cacheWrite':0,'totalTokens':18}\n"
        "if mode == 'zero_usage': usage = {key:0 for key in usage}\n"
        "message = {'role':'assistant','provider':arg('--provider'),'model':arg('--model'),\n"
        "    'stopReason':'stop','content':[{'type':'text','text':json.dumps(result)}], 'usage':usage}\n"
        "if mode == 'no_usage': del message['usage']\n"
        "if mode == 'wrong_model': message['model'] = 'unapproved'\n"
        "if mode == 'auth': message.update(stopReason='error',errorMessage='401 '+key)\n"
        "if mode == 'runtime': message.update(stopReason='error',errorMessage='transient upstream failure '+key)\n"
        "if mode == 'duplicate_key': message['content'][0]['text'] = '{\"status\":\"ok\",\"status\":\"bad\"}'\n"
        "records = [{'type':'session','cwd':os.getcwd()},{'type':'agent_start'},\n"
        "    {'type':'message_end','message':message}, {'type':'agent_end','willRetry':False}, {'type':'agent_settled'}]\n"
        "if mode == 'wrong_cwd': records[0]['cwd'] = '/wrong'\n"
        "if mode == 'missing_terminal': records.pop()\n"
        "if mode == 'tool_then_success': records.insert(2, {'type':'tool_execution_start','toolName':'bash'})\n"
        "if mode == 'extra_turn': records.insert(3,records[2])\n"
        "if mode == 'after_terminal': records.append({'type':'agent_start'})\n"
        "for index, record in enumerate(records):\n"
        "    text = json.dumps(record)\n"
        "    if mode == 'truncated' and index == len(records)-1: sys.stdout.write(text)\n"
        "    else: print(text, flush=True)\n"
        "if mode == 'exit_failed': sys.exit(3)\n"
    )
    return {"node": Path(sys.executable).resolve(), "pi_cli": script}


def assert_persisted(tmp_path, result, task=TASK):
    path = tmp_path / "attempts" / f"{task['task_id']}.{task['attempt']}.json"
    assert json.loads(path.read_text()) == result
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert path.stat().st_size <= 73728
    assert list((tmp_path / "profiles").iterdir()) == []
    assert not list(path.parent.glob("*.claim"))
    assert not list(path.parent.glob(".*.tmp"))


def test_worker_review_category_is_optional_but_enum_checked(dispatch_module):
    result = {
        **RESULT,
        "reviewed_units": ["section-1"],
        "findings": [
            {
                "severity": "important",
                "location": "docs/plan.md:12",
                "summary": "Missing dependency",
                "evidence": "The referenced task is absent.",
                "recommendation": "Add the dependency.",
                "category": "Missing Task",
            }
        ],
    }
    assert dispatch_module._validate_result(json.dumps(result), "fixture-key") == result

    result["findings"][0]["category"] = "Made Up"
    with pytest.raises(ValueError, match="finding_schema"):
        dispatch_module._validate_result(json.dumps(result), "fixture-key")

    result["findings"][0].pop("category")
    assert dispatch_module._validate_result(json.dumps(result), "fixture-key") == result

    result["findings"][0]["auto_fix"] = {"kind": "prose_typo"}
    with pytest.raises(ValueError, match="finding_schema"):
        dispatch_module._validate_result(json.dumps(result), "fixture-key")


def test_worker_reviewed_units_are_unique_strings(dispatch_module):
    result = {**RESULT, "reviewed_units": ["section-1"]}
    assert dispatch_module._validate_result(json.dumps(result), "fixture-key") == result
    for units in (["section-1", "section-1"], ["section-1", 1], "section-1"):
        result["reviewed_units"] = units
        with pytest.raises(ValueError, match="result_reviewed_units"):
            dispatch_module._validate_result(json.dumps(result), "fixture-key")


def test_real_pi_success(make_dispatcher, tmp_path):
    with endpoint(response=RESULT, expected_key="approved-fixture-not-a-secret") as (
        url,
        requests,
        _,
    ):
        result = make_dispatcher(url).run(TASK)
    assert result["status"] == "completed", result
    assert result["result"] == RESULT
    assert result["usage"]["source"] == "reported"
    assert result["usage"]["input"] == 11
    assert result["cost"] == "unknown"
    assert len(requests) == 1 and not requests[0].get("tools")
    assert_persisted(tmp_path, result)


@pytest.mark.parametrize(
    "kind,status",
    [
        ("auth", "auth_error"),
        ("tool", "invalid_output"),
        ("missing_usage", "completed"),
    ],
)
def test_real_pi_failure_and_measurement_boundaries(
    make_dispatcher, tmp_path, kind, status
):
    options = {"response": RESULT}
    if kind == "auth":
        options["status"] = 401
    elif kind == "tool":
        options["tool_call"] = {
            "name": "bash",
            "arguments": '{"command":"echo forbidden"}',
        }
    else:
        options["usage"] = False
    with endpoint(**options) as (url, _, _):
        result = make_dispatcher(url).run(TASK)
    assert result["status"] == status, result
    if kind == "missing_usage":
        assert result["usage"] == "unknown"
    else:
        assert result["result"] is None
    assert_persisted(tmp_path, result)


@pytest.mark.parametrize(
    "mode,status",
    [
        ("ok", "completed"),
        ("stderr_key", "completed"),
        ("no_usage", "completed"),
        ("zero_usage", "completed"),
        ("malformed", "invalid_output"),
        ("bad_utf8", "invalid_output"),
        ("truncated", "invalid_output"),
        ("missing_terminal", "invalid_output"),
        ("after_terminal", "invalid_output"),
        ("extra_turn", "invalid_output"),
        ("wrong_model", "invalid_output"),
        ("wrong_cwd", "invalid_output"),
        ("bad_schema", "invalid_output"),
        ("duplicate_key", "invalid_output"),
        ("tool_then_success", "invalid_output"),
        ("secret_result", "invalid_output"),
        ("auth", "auth_error"),
        ("runtime", "runtime_error"),
        ("exit_failed", "runtime_error"),
        ("flood_stdout", "output_limit"),
        ("flood_stderr", "output_limit"),
    ],
)
def test_adversarial_process_output(make_dispatcher, tmp_path, mode, status):
    result = make_dispatcher(**fake_cli(tmp_path, mode), output_limit=32768).run(TASK)
    assert result["status"] == status, result
    assert_persisted(tmp_path, result)
    stored = json.dumps(result)
    assert "approved-fixture-not-a-secret" not in stored
    assert TASK["prompt"] not in stored
    assert result["cost"] == "unknown"
    if mode in ("no_usage", "zero_usage"):
        assert result["usage"] == "unknown"
    if status != "completed":
        assert result["result"] is None


def test_early_stdin_close_cannot_complete(make_dispatcher, tmp_path):
    task = {**TASK, "prompt": "x" * 131072}
    result = make_dispatcher(**fake_cli(tmp_path, "early_stdin")).run(task)
    assert result["status"] == "runtime_error", result
    assert result["reason"] == "task_delivery_failed"
    assert result["result"] is None
    assert_persisted(tmp_path, result)


def test_timeout_kills_group_including_term_resistant_descendant(
    make_dispatcher, tmp_path
):
    result = make_dispatcher(**fake_cli(tmp_path, "child_hang"), timeout_s=0.5).run(
        TASK
    )
    assert result["status"] == "timeout", result
    heartbeat = tmp_path / "heartbeat"
    assert heartbeat.exists()
    size = heartbeat.stat().st_size
    time.sleep(0.15)
    assert heartbeat.stat().st_size == size
    assert result["duration_s"] < 3
    assert_persisted(tmp_path, result)


def test_cancel_running_process(make_dispatcher, tmp_path):
    cancelled = threading.Event()
    dispatcher = make_dispatcher(**fake_cli(tmp_path, "hang"))
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(dispatcher.run, TASK, cancel=cancelled)
        deadline = time.monotonic() + 3
        while not (tmp_path / "started").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert (tmp_path / "started").exists()
        cancelled.set()
        result = future.result(timeout=3)
    assert result["status"] == "cancelled"
    assert_persisted(tmp_path, result)


@pytest.mark.parametrize("cancelled", [True, False])
def test_queue_budget_and_cancel_before_launch(make_dispatcher, tmp_path, cancelled):
    dispatcher = make_dispatcher(**fake_cli(tmp_path), timeout_s=0.1, max_workers=1)
    event = threading.Event()
    if cancelled:
        event.set()
    dispatcher.slots.acquire()
    try:
        result = dispatcher.run(TASK, cancel=event)
    finally:
        dispatcher.slots.release()
    assert result["status"] == ("cancelled" if cancelled else "timeout")
    assert not (tmp_path / "received-prompt").exists()
    assert_persisted(tmp_path, result)


def test_concurrency_bound(make_dispatcher, tmp_path):
    dispatcher = make_dispatcher(**fake_cli(tmp_path, "concurrency"), max_workers=2)
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(
            pool.map(
                dispatcher.run, [{**TASK, "task_id": f"job-{i}"} for i in range(6)]
            )
        )
    assert all(result["status"] == "completed" for result in results), results
    timeline = sorted(
        json.loads(line) for line in (tmp_path / "timeline").read_text().splitlines()
    )
    active = peak = 0
    for _, change in timeline:
        active += change
        peak = max(peak, active)
    assert active == 0 and peak == 2
    for result in results:
        assert_persisted(tmp_path, result, result)


@pytest.mark.parametrize(
    "extra",
    [
        {"approval": {"approved": True}},
        {"credential": "forbidden"},
        {"cwd": "/"},
        {"tools": ["bash"]},
        {"state_root": "/"},
        {"task_id": "../escape"},
        {"attempt": True},
        {"role": "admin"},
        {"prompt": "x" * 131073},
    ],
)
def test_task_cannot_override_authority(make_dispatcher, tmp_path, extra):
    result = make_dispatcher(**fake_cli(tmp_path)).run({**TASK, **extra})
    assert result["status"] == "configuration_error"
    assert not (tmp_path / "received-prompt").exists()
    assert not (tmp_path / "attempts").exists()


def test_prompt_is_stdin_data_not_shell_or_atfile_expansion(make_dispatcher, tmp_path):
    prompt = f"--model other @/private/file $(touch {tmp_path}/injected) `echo no`\nU+2028: \u2028"
    result = make_dispatcher(**fake_cli(tmp_path)).run({**TASK, "prompt": prompt})
    assert result["status"] == "completed"
    assert json.loads((tmp_path / "received-prompt").read_text())["task"] == prompt
    assert not (tmp_path / "injected").exists()


def test_immutable_attempt_and_existing_claim(make_dispatcher, tmp_path):
    dispatcher = make_dispatcher(**fake_cli(tmp_path))
    first = dispatcher.run(TASK)
    path = tmp_path / "attempts/review.1.json"
    saved = path.read_bytes()
    assert first["status"] == "completed"
    assert dispatcher.run(TASK)["status"] == "state_error"
    assert path.read_bytes() == saved
    claim = tmp_path / "attempts/review.2.json.claim"
    claim.write_text("other writer")
    assert dispatcher.run({**TASK, "attempt": 2})["status"] == "state_error"
    assert claim.read_text() == "other writer"


@pytest.mark.parametrize("kind", ["directory", "ancestor", "leaf", "claim", "dotdot"])
def test_state_path_escape_refused(make_dispatcher, tmp_path, kind):
    external = tmp_path / "external"
    external.mkdir()
    state = tmp_path / "attempts"
    if kind == "directory":
        state.symlink_to(external, target_is_directory=True)
    elif kind == "ancestor":
        state.symlink_to(external, target_is_directory=True)
        state = state / "nested"
    elif kind == "dotdot":
        state = state / ".." / "external"
    else:
        state.mkdir()
        (
            state / ("review.1.json" if kind == "leaf" else "review.1.json.claim")
        ).symlink_to(external / "target")
    result = make_dispatcher(**fake_cli(tmp_path), state_root=state).run(TASK)
    assert result["status"] == "state_error"
    assert list(external.iterdir()) == []
    assert not (tmp_path / "received-prompt").exists()


def test_state_failure_cannot_report_completion(
    make_dispatcher, tmp_path, dispatch_module, monkeypatch
):
    def fail_write(self, value):
        raise OSError("disk failure with untrusted diagnostic")

    monkeypatch.setattr(dispatch_module.AttemptStore, "write", fail_write)
    result = make_dispatcher(**fake_cli(tmp_path)).run(TASK)
    assert result["status"] == "state_error" and result["result"] is None
    assert "untrusted" not in json.dumps(result)
    assert not list((tmp_path / "attempts").iterdir())


def test_tier_mapping_is_trusted_configuration(
    make_dispatcher, tmp_path, dispatch_module, monkeypatch
):
    dispatcher = make_dispatcher(**fake_cli(tmp_path))
    mapped = dict(dispatcher.selected.approval, model="approved-mechanical")
    overrides = {
        "mechanical": dispatch_module.approve_selection(
            mapped, "tier-fixture-key", confirm=lambda _summary: True
        )
    }
    dispatcher = make_dispatcher(**fake_cli(tmp_path), tier_overrides=overrides)
    monkeypatch.setenv("PI_MODEL", "unapproved-default")
    mapped["model"] = "mutated-after-construction"
    selected = dispatcher.run(TASK)
    mechanical = dispatcher.run({**TASK, "attempt": 2, "role": "mechanical"})
    assert selected["status"] == mechanical["status"] == "completed"
    assert selected["model_source"] == "approved_selected"
    assert mechanical["model_source"] == "tier_override"
    assert mechanical["model"]["model"] == "approved-mechanical"


def test_selection_requires_explicit_confirmation(dispatch_module):
    record = {
        "approved": True,
        "provider": "fixture-provider",
        "model": "fixture-model",
        "api": "openai-completions",
        "base_url": "https://example.invalid/v1",
        "thinking": "off",
        "context_window": 32000,
        "max_tokens": 1000,
        "credential_type": "api_key",
    }
    key = "private-fixture-key"
    with pytest.raises(
        dispatch_module.ProfileError, match="^selection_authority_required$"
    ):
        dispatch_module.Selection(record, key)
    seen = []
    with pytest.raises(
        dispatch_module.ProfileError, match="^operator_confirmation_required$"
    ):
        dispatch_module.approve_selection(
            record, key, confirm=lambda summary: seen.append(summary) or False
        )
    assert len(seen) == 1
    assert key not in repr(seen[0])
    selection = dispatch_module.approve_selection(
        record,
        key,
        confirm=lambda summary: summary[0:2] == ("fixture-provider", "fixture-model"),
    )
    assert key not in repr(selection)


def test_nested_dispatch_refused(make_dispatcher, dispatch_module, monkeypatch):
    monkeypatch.setenv("SKEIN_PI_WORKER_DEPTH", "1")
    with pytest.raises(dispatch_module.ProfileError, match="^nested_dispatch_refused$"):
        make_dispatcher()
