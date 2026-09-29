"""Private-profile preparation only: no process launch, dispatcher, or skill routing.

The caller supplies an operator-approved record and one literal API key through
separate trusted channels, never from task/model output. ``approved`` records
that caller decision; it is not an authentication/provenance mechanism. This
module does not inspect the parent's settings, environment, or credentials.

Initial verified lane: text-only openai-completions, thinking=off, no tools.
OAuth, command credentials, ambient cloud auth, extension providers and tool
execution fail closed until their separate isolation contracts are tested.
"""

import json
import os
import re
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


class ProfileError(ValueError):
    """Safe fixed diagnostic; never embed rejected input or credential values."""


@dataclass(frozen=True)
class PrivateProfile:
    root: Path
    agent_dir: Path
    cwd: Path
    argv: tuple[str, ...]
    env: dict[str, str]


def validate_approval(record, credential):
    """Validate an explicit trusted selection; never infer identity or fallback."""
    fields = {
        "approved",
        "provider",
        "model",
        "api",
        "base_url",
        "thinking",
        "context_window",
        "max_tokens",
        "credential_type",
    }
    if not isinstance(record, dict) or set(record) != fields:
        raise ProfileError("approval_schema_invalid")
    if record["approved"] is not True:
        raise ProfileError("operator_approval_required")
    if record["credential_type"] != "api_key":
        raise ProfileError("credential_type_unsupported")
    if record["api"] != "openai-completions" or record["thinking"] != "off":
        raise ProfileError("provider_lane_unsupported")
    # Restrict the initial lane to IDs without CLI fuzzy-pattern/suffix syntax.
    # Exact model availability still requires endpoint/preflight validation;
    # creating a catalog entry does not prove a remote server implements it.
    for key in ("provider", "model"):
        value = record[key]
        if not isinstance(value, str) or not re.fullmatch(
            r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}", value
        ):
            raise ProfileError("identity_invalid")
    for key in ("context_window", "max_tokens"):
        if type(record[key]) is not int or not 1 <= record[key] <= 10_000_000:
            raise ProfileError("model_limits_invalid")
    if record["max_tokens"] > record["context_window"]:
        raise ProfileError("model_limits_invalid")
    url = record["base_url"]
    if (
        not isinstance(url, str)
        or any(char in url for char in ("!", "$", "\\"))
        or any(char.isspace() for char in url)
    ):
        raise ProfileError("endpoint_invalid")
    try:
        parsed = urlsplit(url)
        port = parsed.port
        allowed_scheme = parsed.scheme == "https" or (
            parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "::1"}
        )
        valid = (
            allowed_scheme
            and parsed.hostname
            and parsed.username is None
            and parsed.password is None
            and not parsed.query
            and not parsed.fragment
            and (port is None or port > 0)
        )
    except ValueError:
        valid = False
    if not valid:
        raise ProfileError("endpoint_invalid")
    # Pi interprets !command and $ interpolation in credential/config values.
    # Accept only non-empty literal single-line keys; never run a secret helper.
    if (
        not isinstance(credential, str)
        or not 1 <= len(credential) <= 16384
        or credential.startswith("!")
        or "$" in credential
        or any(ord(char) < 33 or ord(char) == 127 for char in credential)
    ):
        raise ProfileError("literal_credential_required")
    return dict(record)


def _private_write(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(content)


def _trusted_file(path, executable=False):
    path = Path(path)
    if not path.is_absolute():
        raise ProfileError("absolute_runtime_path_required")
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or (executable and not os.access(resolved, os.X_OK)):
        raise ProfileError("runtime_unavailable")
    return resolved


@contextmanager
def private_profile(
    *,
    approval,
    credential,
    node,
    pi_cli,
    cwd,
    temp_root,
    system_prompt,
    project_rules,
    tools=(),
):
    """Create and remove one private profile within an operator-selected temp root.

    Caller must reap any child before exiting this context. No environment is
    inherited, no user config is copied, and no credential is placed in argv/env.
    Cleanup is ordinary deletion, not secure erasure; SIGKILL/host failure can
    leave a mode-0700 directory requiring operator cleanup. Same-UID processes
    can still read it: this is startup/context isolation, not an OS sandbox.
    """
    selection = validate_approval(approval, credential)
    if tools != ():
        raise ProfileError("tools_not_yet_supported")
    if not isinstance(system_prompt, str) or not system_prompt.strip():
        raise ProfileError("curated_prompt_required")
    if (
        not isinstance(project_rules, str)
        or len(system_prompt) + len(project_rules) > 200_000
    ):
        raise ProfileError("curated_prompt_invalid")
    node = _trusted_file(node, executable=True)
    pi_cli = _trusted_file(pi_cli)
    cwd, temp_root = Path(cwd), Path(temp_root)
    if not cwd.is_absolute() or not temp_root.is_absolute():
        raise ProfileError("absolute_directory_required")
    cwd, temp_root = cwd.resolve(strict=True), temp_root.resolve(strict=True)
    if not cwd.is_dir() or not temp_root.is_dir():
        raise ProfileError("directory_unavailable")
    with tempfile.TemporaryDirectory(
        prefix="skein-pi-worker-", dir=temp_root
    ) as directory:
        root = Path(directory)
        root.chmod(0o700)
        home, agent, scratch = root / "home", root / "agent", root / "tmp"
        for path in (home, agent, scratch):
            path.mkdir(mode=0o700)
        settings = {
            "packages": [],
            "extensions": [],
            "skills": [],
            "prompts": [],
            "themes": [],
            "defaultProjectTrust": "never",
            "enableSkillCommands": False,
            "defaultTools": [],
            "retry": {"enabled": False},
            "compaction": {"enabled": False},
            "enableInstallTelemetry": False,
            "enableAnalytics": False,
            "cacheWarming": "off",
        }
        model = {
            "id": selection["model"],
            "reasoning": False,
            "input": ["text"],
            "contextWindow": selection["context_window"],
            "maxTokens": selection["max_tokens"],
        }
        models = {
            "providers": {
                selection["provider"]: {
                    "baseUrl": selection["base_url"],
                    "api": selection["api"],
                    "models": [model],
                }
            }
        }
        auth = {selection["provider"]: {"type": "api_key", "key": credential}}
        for name, value in (
            ("settings.json", settings),
            ("models.json", models),
            ("auth.json", auth),
        ):
            _private_write(agent / name, json.dumps(value))
        system_file, rules_file = root / "role.md", root / "rules.md"
        _private_write(system_file, system_prompt)
        _private_write(rules_file, project_rules or "No additional project rules.")
        # Direct Node launch avoids /usr/bin/env node consulting a poisoned PATH.
        # All executable paths and directories are caller-approved, not task data.
        argv = (
            str(node),
            str(pi_cli),
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
            "--session-dir",
            str(root / "sessions"),
            "--system-prompt",
            str(system_file),
            "--append-system-prompt",
            str(rules_file),
            "--provider",
            selection["provider"],
            "--model",
            selection["model"],
            "--thinking",
            selection["thinking"],
        )
        env = {
            "HOME": str(home),
            "PI_CODING_AGENT_DIR": str(agent),
            "TMPDIR": str(scratch),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "XDG_DATA_HOME": str(home / ".local/share"),
            "PATH": os.defpath,
            "PI_OFFLINE": "1",
            "PI_SKIP_VERSION_CHECK": "1",
            "PI_TELEMETRY": "0",
            "SKEIN_PI_WORKER_DEPTH": "1",
            "PI_CODING_AGENT_SESSION_DIR": str(root / "sessions"),
        }
        yield PrivateProfile(root=root, agent_dir=agent, cwd=cwd, argv=argv, env=env)
