"""Phase 1 real-Pi package checks; no credentials, model calls, or user settings.

Requires pi on PATH (validated with 0.87.1), git, and Node via Pi's launcher.
Missing Pi is a failure, not a silently skipped readiness gate.
"""

import json
import os
import selectors
import shutil
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SKILL = "plugins/skein-pi/skills/show-me/SKILL.md"
ALLOWLIST = [
    "./plugins/skein-pi/skills/show-me/SKILL.md",
    "./plugins/skein-pi/skills/content-draft/SKILL.md",
    "./plugins/skein-pi/skills/content-review/SKILL.md",
    "./plugins/skein-pi/skills/update-docs/SKILL.md",
    "./plugins/skein-pi/skills/dev-plan/SKILL.md",
    "./plugins/skein-pi/skills/grill/SKILL.md",
]
COMMANDS = [
    "skill:skein-show-me",
    "skill:skein-content-draft",
    "skill:skein-content-review",
    "skill:skein-update-docs",
    "skill:skein-dev-plan",
    "skill:skein-grill",
]


def run(argv, env, cwd):
    return subprocess.run(
        argv, env=env, cwd=cwd, text=True, capture_output=True, check=True, timeout=60
    ).stdout


@pytest.fixture
def sandbox(tmp_path):
    pi = shutil.which("pi")
    assert pi, "Install Pi CLI before running the Pi readiness suite"
    home = tmp_path / "disposable home"
    agent = home / "agent"
    cwd = tmp_path / "unrelated workspace"
    agent.mkdir(parents=True)
    cwd.mkdir()
    # Allowlist environment: do not inherit API keys, NODE_OPTIONS, Pi overrides,
    # Git rewrites, or the person's settings/home. All writes stay under tmp_path.
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "PI_CODING_AGENT_DIR": str(agent),
        "PI_OFFLINE": "1",
        "PI_SKIP_VERSION_CHECK": "1",
        "PI_TELEMETRY": "0",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(home / "gitconfig"),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ALLOW_PROTOCOL": "file",
    }
    return pi, env, cwd, agent


def package_fixture(path):
    path.mkdir(parents=True)
    shutil.copy2(ROOT / "package.json", path / "package.json")
    manifest = json.loads((ROOT / "package.json").read_text())
    for skill_path in manifest["pi"]["skills"]:
        source_dir = (ROOT / skill_path).parent
        target_dir = (path / skill_path).parent
        shutil.copytree(source_dir, target_dir)
    shutil.copy2(
        ROOT / "plugins/skein-pi/extension.ts", path / "plugins/skein-pi/extension.ts"
    )
    shutil.copytree(
        ROOT / "plugins/skein-pi/lib",
        path / "plugins/skein-pi/lib",
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
    )
    # Real files outside the allowlist must not become commands, even if valid.
    for extra in (
        "plugins/skein-pi/skills/deep-review/SKILL.md",
        "plugins/skein-pi/skills/plan-view/SKILL.md",
        "plugins/skein/skills/show-me/SKILL.md",
        "plugins/skein-codex/skills/show-me/SKILL.md",
        "skills/unfinished/SKILL.md",
    ):
        target = path / extra
        target.parent.mkdir(parents=True)
        target.write_text(
            "---\nname: unfinished\ndescription: Must not load.\n---\nNo.\n"
        )
    return path


@contextmanager
def rpc(sandbox):
    pi, env, cwd, _ = sandbox
    process = subprocess.Popen(
        [
            pi,
            "--mode",
            "rpc",
            "--no-session",
            "--no-extensions",
            "--no-context-files",
            "--no-approve",
            "--no-tools",
            "--no-prompt-templates",
            "--no-themes",
            "--offline",
        ],
        env=env,
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    selector.register(process.stderr, selectors.EVENT_READ)
    pending = b""
    errors = b""
    counter = 0

    def request(kind, **kwargs):
        nonlocal pending, errors, counter
        counter += 1
        request_id = str(counter)
        process.stdin.write(
            json.dumps({"id": request_id, "type": kind, **kwargs}).encode() + b"\n"
        )
        process.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                record = json.loads(line)
                if record.get("id") == request_id:
                    assert record.get("success"), record
                    return record.get("data")
            for key, _ in selector.select(timeout=0.2):
                chunk = os.read(key.fileobj.fileno(), 65536)
                assert chunk, f"Pi exited early: {errors.decode(errors='replace')}"
                if key.fileobj is process.stderr:
                    errors += chunk
                else:
                    pending += chunk
        pytest.fail(f"Pi RPC timeout: {errors.decode(errors='replace')}")

    try:
        yield request
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


def assert_discovery(sandbox, package):
    with rpc(sandbox) as request:
        commands = [
            c for c in request("get_commands")["commands"] if c["source"] == "skill"
        ]
        assert [c["name"] for c in commands] == COMMANDS
        command = next(c for c in commands if c["name"] == "skill:skein-show-me")
        assert command["source"] == "skill"
        assert (
            Path(command["sourceInfo"]["path"]).resolve() == (package / SKILL).resolve()
        )
        # Queue then inspect: exercises Pi's real /skill expansion with arguments,
        # without sending a prompt to a provider or claiming an LLM behaviour test.
        request("steer", message="/skill:skein-show-me explain the request call tree")
        queued = request("clear_queue")["steering"]
        assert len(queued) == 1
        body = (package / SKILL).read_text().split("---\n", 2)[2].strip()
        assert body in queued[0]
        assert "explain the request call tree" in queued[0]
        assert str(package / SKILL) in queued[0]
        for name, argument in (
            ("content-draft", '--type til --title "Fixture"'),
            ("content-review", "draft.md --type technical-doc"),
            ("update-docs", ""),
            ("dev-plan", "create feature fixture"),
            ("grill", "A bounded fixture idea"),
        ):
            skill_path = f"plugins/skein-pi/skills/{name}/SKILL.md"
            request("steer", message=f"/skill:skein-{name} {argument}")
            expanded = request("clear_queue")["steering"]
            assert len(expanded) == 1
            assert (package / skill_path).read_text().split("---\n", 2)[
                2
            ].strip() in expanded[0]
            assert argument in expanded[0]
            assert str(package / skill_path) in expanded[0]


def test_manifest_exact_allowlist():
    manifest = json.loads((ROOT / "package.json").read_text())
    assert manifest["pi"] == {
        "skills": ALLOWLIST,
        "extensions": ["./plugins/skein-pi/extension.ts"],
        "prompts": [],
        "themes": [],
    }
    assert "pi-package" in manifest["keywords"]
    assert not manifest.get("dependencies")
    assert not manifest.get("scripts")
    assert (ROOT / SKILL).is_file()


@pytest.mark.parametrize("folder", ["package", "package with spaces"])
def test_local_install_restart_update_remove(tmp_path, sandbox, folder):
    pi, env, cwd, agent = sandbox
    package = package_fixture(tmp_path / folder)
    run([pi, "install", str(package)], env, cwd)
    settings = json.loads((agent / "settings.json").read_text())
    assert len(settings["packages"]) == 1
    assert (agent / settings["packages"][0]).resolve() == package.resolve()
    assert_discovery(sandbox, package)
    run([pi, "update", str(package)], env, cwd)
    assert_discovery(sandbox, package)  # New Pi process = restart-based discovery.
    run([pi, "remove", str(package)], env, cwd)
    with rpc(sandbox) as request:
        assert not any(
            c["source"] == "skill" for c in request("get_commands")["commands"]
        )
    assert (package / SKILL).is_file()  # Removing local install does not delete source.


def test_commit_pinned_git_install(tmp_path, sandbox):
    pi, env, cwd, agent = sandbox
    package = package_fixture(tmp_path / "committed fixture with spaces")
    run(["git", "init", str(package)], env, cwd)
    run(
        ["git", "-C", str(package), "add", "package.json", "plugins", "skills"],
        env,
        cwd,
    )
    commit = [
        "git",
        "-C",
        str(package),
        "-c",
        "user.name=Pi Test",
        "-c",
        "user.email=pi-test@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-m",
    ]
    run([*commit, "ready fixture"], env, cwd)
    pin = run(["git", "-C", str(package), "rev-parse", "HEAD"], env, cwd).strip()
    # Advance HEAD to prove installation honours the commit, not the default branch.
    (package / SKILL).write_text("broken unpinned revision\n")
    run(["git", "-C", str(package), "add", SKILL], env, cwd)
    run([*commit, "unready later revision"], env, cwd)
    url = "https://pi-fixture.invalid/team/skein"
    run(
        ["git", "config", "--global", f"url.{package.as_uri()}.insteadOf", url],
        env,
        cwd,
    )
    source = f"git:{url}@{pin}"
    run([pi, "install", source], env, cwd)
    installed = list((agent / "git").rglob("package.json"))
    assert len(installed) == 1
    checkout = installed[0].parent
    assert (
        run(["git", "-C", str(checkout), "rev-parse", "HEAD"], env, cwd).strip() == pin
    )
    assert_discovery(sandbox, checkout)
    run([pi, "update", source], env, cwd)
    assert (
        run(["git", "-C", str(checkout), "rev-parse", "HEAD"], env, cwd).strip() == pin
    )
    assert_discovery(sandbox, checkout)
    run([pi, "remove", source], env, cwd)
    with rpc(sandbox) as request:
        assert not any(
            c["source"] == "skill" for c in request("get_commands")["commands"]
        )
