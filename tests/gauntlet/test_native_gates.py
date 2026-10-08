"""Native-gate envelopes and immutable review input, using real Git fixtures."""

import importlib.util
import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "plugins/skein-codex/skills/review-gauntlet/native_gates.py"
spec = importlib.util.spec_from_file_location("native_gates", SOURCE)
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)
SCHEMA = json.loads(gates.SCHEMA_PATH.read_text())


def command(*args, cwd, stdin=None):
    return subprocess.run(args, cwd=cwd, input=stdin, capture_output=True, check=True)


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "source"
    root.mkdir()
    command("git", "init", "-q", cwd=root)
    (root / "a.py").write_text("value = 1\n")
    command("git", "add", "a.py", cwd=root)
    command(
        "git",
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "baseline",
        cwd=root,
    )
    return root


@pytest.fixture
def fake_codex(tmp_path, monkeypatch, repo):
    fake = tmp_path / "fake-codex"
    fake.write_text(r"""#!/usr/bin/env python3
import json, os, pathlib, sys
mode = os.environ.get('NATIVE_GATE_TEST_MODE', '')
source = pathlib.Path(os.environ['NATIVE_GATE_TEST_SOURCE'])
assert pathlib.Path.cwd() != source
if sys.argv[1] == 'app-server':
    assert 'model_reasoning_effort="medium"' in sys.argv
    def emit(method, params):
        print(json.dumps({'method':method,'params':params}),flush=True)
    def reply(identifier, result):
        print(json.dumps({'id':identifier,'result':result}),flush=True)
    for line in sys.stdin:
        req=json.loads(line)
        if req['method']=='initialize':
            assert req['params']['capabilities']['experimentalApi'] is True
            reply(req['id'],{})
        elif req['method']=='thread/start':
            assert req['params']['ephemeral'] is True
            assert req['params']['sandbox']=='read-only'
            assert req['params']['approvalPolicy']=='never'
            assert req['params']['experimentalRawEvents'] is True
            reply(req['id'],{'thread':{'id':'test-thread'}})
        elif req['method']=='review/start':
            assert req['params']['threadId']=='test-thread' and req['params']['delivery']=='inline'
            assert req['params']['target']['type'] in ['baseBranch','uncommittedChanges']
            if mode == 'source-edit': (source / 'a.py').write_text('value = 99\n')
            if mode == 'snapshot-edit': pathlib.Path('a.py').write_text('value = 99\n')
            if mode == 'interactive':
                print(json.dumps({'id':99,'method':'item/requestApproval','params':{}}),flush=True)
                continue
            if mode == 'bad-response':
                reply(req['id'],{})
                continue
            reply(req['id'],{'reviewThreadId':'test-thread','turn':{'id':'test-turn'}})
            emit('turn/started',{'threadId':'test-thread','turn':{'id':'native-delegate-turn'}})
            result={'findings':[],'overall_correctness':'patch is correct','overall_explanation':'Clean','overall_confidence_score':0.99}
            if mode == 'finding':
                result.update(overall_correctness='patch is incorrect',findings=[{
                    'title':'[P2] Defect','body':'value = 1','priority':2,'confidence_score':0.95,
                    'code_location':{'absolute_file_path':str(pathlib.Path.cwd()/'a.py'),'line_range':{'start':1,'end':1}}}])
            if mode == 'unknown-field':result['invented']=True
            if mode == 'missing-verdict':result.pop('overall_correctness')
            if mode == 'contradictory':result['overall_correctness']='patch is incorrect'
            report=json.dumps(result)
            if mode == 'prose':report='No issues found.'
            if mode == 'multiple-documents':report+=' '+report
            params={'threadId':'test-thread','turnId':'test-turn','item':{'type':'message','role':'assistant','phase':'final_answer','content':[{'type':'output_text','text':report}]}}
            if mode == 'wrong-gate':params['turnId']='other-turn'
            if mode == 'bad-item':params['item']=None
            if mode != 'no-raw-result':emit('rawResponseItem/completed',params)
            if mode == 'duplicate-result':emit('rawResponseItem/completed',params)
            # The native parent emits rendered prose too. It cannot replace the raw verdict.
            emit('rawResponseItem/completed',{'threadId':'test-thread','turnId':'test-turn','item':{'type':'message','role':'assistant','content':[{'type':'output_text','text':'display text'}]}})
            if mode != 'no-completion':
                emit('turn/completed',{'threadId':'test-thread','turn':{'id':'test-turn','status':'failed' if mode=='failed-turn' else 'completed','error':None}})
            break
else:
    schema = json.loads(pathlib.Path(sys.argv[sys.argv.index('--output-schema')+1]).read_text())
    assert schema['additionalProperties'] is False
    gate = 'codex-adversarial'
    assert 'model_reasoning_effort="medium"' in sys.argv
    if mode == 'prose':
        print('No issues found.')
    else:
        result = {'gate':gate,'status':'approve','findings':[], 'notes':None}
        if mode == 'finding':
            path = pathlib.Path.cwd() / 'a.py'
            result.update(status='needs-attention', findings=[{'file':str(path), 'line':1,
                'category':'CodeReview', 'severity':'Important', 'confidence':None,
                'summary':'Defect', 'evidence':'value = 1', 'auto_fix':None}])
        if mode == 'unknown-field': result['invented'] = True
        if mode == 'wrong-gate': result['gate'] = 'codex-adversarial' if gate=='codex-review' else 'codex-review'
        print(json.dumps(result))
        if mode == 'multiple-documents': print(json.dumps(result))
""")
    fake.chmod(0o755)
    monkeypatch.setenv("NATIVE_GATE_TEST_SOURCE", str(repo))
    return str(fake)


def request(repo, codex, *, uncommitted=False, gate="codex-review"):
    state = gates.capture(repo)
    return gates.argparse.Namespace(
        repo=str(repo),
        expected=state["fingerprint"],
        head=state["head"],
        base=state["head"],
        codex=codex,
        uncommitted=uncommitted,
        gate=gate,
    )


def clean(gate="codex-review"):
    return {
        "gate": gate,
        "status": "approve",
        "findings": [],
        "notes": "Clean" if gate == "codex-review" else None,
    }


def finding():
    return {
        "file": "a.py",
        "line": 1,
        "category": "Logic",
        "severity": "Important",
        "confidence": None,
        "summary": "Defect",
        "evidence": "value = 1",
        "auto_fix": None,
    }


def test_schema_is_closed_and_strict_at_every_object():
    def walk(value):
        if isinstance(value, dict):
            if value.get("type") == "object":
                assert value["additionalProperties"] is False
                assert set(value["required"]) == set(value["properties"])
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(SCHEMA)


@pytest.mark.parametrize(
    "proposal",
    [
        {},
        {"kind": "unused_var", "before": "x", "after": ""},
        {
            "kind": "unused_var",
            "before": "x",
            "after": "",
            "scope": "a.py",
            "extra": True,
        },
    ],
)
def test_nested_auto_fix_rejects_missing_or_unknown_fields(proposal):
    value = clean()
    item = finding()
    item["auto_fix"] = proposal
    value.update(status="needs-attention", findings=[item])
    with pytest.raises(gates.GateError):
        gates.validate(value, SCHEMA)


def test_strict_schema_accepts_complete_nullable_auto_fix():
    value = clean()
    item = finding()
    item["auto_fix"] = {
        "kind": "unused_var",
        "before": "x",
        "after": "",
        "scope": "a.py",
    }
    value.update(status="needs-attention", findings=[item])
    gates.validate(value, SCHEMA)


@pytest.mark.parametrize("text", ['{"a":1,"a":2}', '{"a":NaN}', "{}\n{}"])
def test_strict_json_rejects_duplicate_nonfinite_or_multiple_documents(text):
    with pytest.raises((gates.GateError, ValueError)):
        gates.strict_json(text)


@pytest.mark.parametrize("gate", ["codex-review", "codex-adversarial"])
def test_actual_gate_pipeline_uses_private_snapshot_and_one_strict_envelope(
    repo, fake_codex, gate
):
    state = gates.capture(repo)
    assert gates.run_gate(request(repo, fake_codex, gate=gate)) == clean(gate)
    assert gates.capture(repo)["fingerprint"] == state["fingerprint"]


@pytest.mark.parametrize(
    "mode",
    [
        "source-edit",
        "snapshot-edit",
        "no-completion",
        "unknown-field",
        "wrong-gate",
        "no-raw-result",
        "duplicate-result",
        "bad-item",
        "failed-turn",
        "interactive",
        "missing-verdict",
        "contradictory",
    ],
)
def test_native_invalid_or_changed_input_cannot_be_approved(
    repo, fake_codex, monkeypatch, mode
):
    monkeypatch.setenv("NATIVE_GATE_TEST_MODE", mode)
    with pytest.raises(gates.GateError):
        gates.run_gate(request(repo, fake_codex))


@pytest.mark.parametrize("mode", ["prose", "multiple-documents"])
def test_prose_and_multiple_envelopes_fail_closed(repo, fake_codex, monkeypatch, mode):
    monkeypatch.setenv("NATIVE_GATE_TEST_MODE", mode)
    with pytest.raises(ValueError):
        gates.run_gate(request(repo, fake_codex))


def test_fingerprint_detects_worktree_index_untracked_and_head_changes(repo):
    baseline = gates.capture(repo)
    (repo / "a.py").write_text("value = 2\n")
    with pytest.raises(gates.GateError):
        gates.require_source(repo, baseline["fingerprint"], baseline["head"])
    changed = gates.capture(repo)
    command("git", "add", "a.py", cwd=repo)
    assert gates.capture(repo)["fingerprint"] != changed["fingerprint"]
    staged = gates.capture(repo)
    (repo / "new,\nfile.py").write_text("new = True\n")
    assert gates.capture(repo)["fingerprint"] != staged["fingerprint"]
    command(
        "git",
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "change",
        cwd=repo,
    )
    with pytest.raises(gates.GateError):
        gates.require_source(repo, baseline["fingerprint"], baseline["head"])


def test_uncommitted_snapshot_preserves_staged_unstaged_untracked_and_symlink_bytes(
    repo, tmp_path
):
    (repo / "a.py").write_text("staged = True\n")
    command("git", "add", "a.py", cwd=repo)
    (repo / "a.py").write_text("unstaged = True\n")
    (repo / "new,\nfile.py").write_bytes(b"\xff\x00A\n")
    (repo / "link.py").symlink_to("a.py")
    state = gates.capture(repo)
    dest = tmp_path / "snapshot"
    frozen = gates.snapshot(repo, dest, state, True)
    assert frozen["files"] == state["files"]
    assert frozen["index"] == state["index"]
    assert gates.capture(repo)["fingerprint"] == state["fingerprint"]


def test_committed_mode_rejects_dirty_source(repo, fake_codex):
    (repo / "a.py").write_text("changed = True\n")
    with pytest.raises(gates.GateError, match="clean checkout"):
        gates.run_gate(request(repo, fake_codex))


def test_uncommitted_gate_remains_supported(repo, fake_codex):
    (repo / "a.py").write_text("changed = True\n")
    assert gates.run_gate(request(repo, fake_codex, uncommitted=True)) == clean()


def test_assume_unchanged_input_is_not_silently_excluded(repo):
    command("git", "update-index", "--assume-unchanged", "a.py", cwd=repo)
    with pytest.raises(gates.GateError, match="assume-unchanged"):
        gates.capture(repo)


def test_cli_error_still_returns_machine_readable_error_envelope(repo):
    result = subprocess.run(
        [
            "python3",
            str(SOURCE),
            "check",
            "--repo",
            str(repo),
            "--head",
            gates.capture(repo)["head"],
            "--expected",
            "wrong",
        ],
        capture_output=True,
        check=False,
    )
    assert result.returncode == 2
    value = json.loads(result.stdout)
    gates.validate(value, SCHEMA)
    assert value["status"] == "error" and value["findings"] == []


@pytest.mark.parametrize("gate", ["codex-review", "codex-adversarial"])
def test_snapshot_finding_paths_are_mapped_back_to_source(
    repo, fake_codex, monkeypatch, gate
):
    monkeypatch.setenv("NATIVE_GATE_TEST_MODE", "finding")
    result = gates.run_gate(request(repo, fake_codex, gate=gate))
    assert result["status"] == "needs-attention"
    assert result["findings"][0]["file"] == "a.py"
    assert result["findings"][0]["line"] == 1


@pytest.mark.parametrize("staged", [False, True])
def test_uncommitted_snapshot_preserves_deletions(repo, tmp_path, staged):
    (repo / "a.py").unlink()
    if staged:
        command("git", "add", "a.py", cwd=repo)
    state = gates.capture(repo)
    dest = tmp_path / "snapshot"
    frozen = gates.snapshot(repo, dest, state, True)
    assert not (dest / "a.py").exists()
    assert frozen["files"] == state["files"]
    assert frozen["index"] == state["index"]


@pytest.mark.parametrize("directory_first", [False, True])
def test_snapshot_preserves_file_directory_transitions(repo, tmp_path, directory_first):
    if directory_first:
        (repo / "a.py").unlink()
        (repo / "a.py").mkdir()
        (repo / "a.py/child.py").write_text("child = True\n")
        command("git", "add", "a.py", cwd=repo)
        command(
            "git",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "directory",
            cwd=repo,
        )
        (repo / "a.py/child.py").unlink()
        (repo / "a.py").rmdir()
        (repo / "a.py").write_text("file = True\n")
    else:
        (repo / "a.py").unlink()
        (repo / "a.py").mkdir()
        (repo / "a.py/child.py").write_text("child = True\n")
    state = gates.capture(repo)
    dest = tmp_path / "snapshot"
    frozen = gates.snapshot(repo, dest, state, True)
    assert frozen["files"] == state["files"]


def test_malformed_native_response_is_a_machine_readable_error(
    repo, fake_codex, monkeypatch
):
    monkeypatch.setenv("NATIVE_GATE_TEST_MODE", "bad-response")
    args = request(repo, fake_codex)
    result = subprocess.run(
        [
            "python3",
            "-I",
            "-S",
            str(SOURCE),
            "run",
            "--repo",
            args.repo,
            "--head",
            args.head,
            "--expected",
            args.expected,
            "--base",
            args.base,
            "--codex",
            args.codex,
        ],
        capture_output=True,
        check=False,
    )
    assert result.returncode == 2
    value = json.loads(result.stdout)
    gates.validate(value, SCHEMA)
    assert value["status"] == "error" and value["findings"] == []


def test_isolated_cli_ignores_poisoned_pythonpath(repo, tmp_path):
    poison = tmp_path / "poison"
    poison.mkdir()
    marker = tmp_path / "imported"
    (poison / "json.py").write_text(
        "from pathlib import Path\nPath("
        + repr(str(marker))
        + ").write_text('poisoned')\nraise RuntimeError('poisoned json import')\n"
    )
    env = dict(os.environ, PYTHONPATH=str(poison))
    result = subprocess.run(
        ["python3", "-I", "-S", str(SOURCE), "fingerprint", "--repo", str(repo)],
        env=env,
        cwd=poison,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0
    assert len(json.loads(result.stdout)["fingerprint"]) == 64
    assert not marker.exists()


@pytest.mark.parametrize(
    "change",
    [
        "unknown-location",
        "missing-body",
        "invalid-range",
        "bad-priority",
        "bad-confidence",
    ],
)
def test_native_structured_findings_require_complete_valid_fields(change):
    item = {
        "title": "[P2] Defect",
        "body": "Evidence",
        "confidence_score": 0.9,
        "priority": 2,
        "code_location": {
            "absolute_file_path": "/snapshot/a.py",
            "line_range": {"start": 1, "end": 2},
        },
    }
    if change == "unknown-location":
        item["code_location"]["extra"] = True
    elif change == "missing-body":
        del item["body"]
    elif change == "invalid-range":
        item["code_location"]["line_range"]["end"] = 0
    elif change == "bad-priority":
        item["priority"] = True
    else:
        item["confidence_score"] = float("inf")
    value = {
        "findings": [item],
        "overall_correctness": "patch is incorrect",
        "overall_explanation": "Defect",
        "overall_confidence_score": 0.9,
    }
    with pytest.raises(gates.GateError):
        gates.native_envelope(value)


def test_gauntlet_checks_pinned_input_across_review_and_mutation_boundaries():
    skill = SOURCE.with_name("SKILL.md").read_text()
    assert skill.index("native_gates.py fingerprint") < skill.index(
        "native_gates.py run"
    )
    for gate in ["codex-review", "codex-adversarial"]:
        assert 'python3 -I -S "$SKILL_DIR"/native_gates.py run --gate ' + gate in skill
    assert 'python3 -I -S "$SKILL_DIR"/native_gates.py check' in skill
    assert (
        "Immediately before **each** trivial applier, fixer dispatch (including retries), and ledger append"
        in skill
    )
    assert '--head "$mutation_head" --expected "$mutation_fingerprint"' in skill
    assert "Only then capture a new `mutation_head`/`mutation_fingerprint`" in skill
    assert "Quick mode uses the same pin/check rules." in skill
    assert "stop before fixes and do not append the ledger" in skill


@pytest.mark.parametrize("setting", ["diff.noprefix", "diff.mnemonicPrefix"])
def test_snapshot_replays_staged_patch_with_source_local_prefix_settings(
    repo, tmp_path, setting
):
    command("git", "config", setting, "true", cwd=repo)
    (repo / "a.py").write_text("staged = True\n")
    command("git", "add", "a.py", cwd=repo)
    (repo / "a.py").write_text("unstaged = True\n")
    state = gates.capture(repo)
    assert b"diff --git a/a.py b/a.py" in state["index"]
    frozen = gates.snapshot(repo, tmp_path / "review", state, True)
    assert frozen["index"] == state["index"]
    assert frozen["files"] == state["files"]
