"""Permission and identity boundaries of the read-only Codex release adapter."""

import importlib.util
import stat
from pathlib import Path
from types import SimpleNamespace

import pytest

SOURCE = Path(__file__).resolve().parents[1] / "executable_policy.py"
SPEC = importlib.util.spec_from_file_location("executable_policy", SOURCE)
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


def allowed(path, executable, *, mode=0o775, uid=501, gid=80, platform="darwin"):
    info = SimpleNamespace(st_mode=stat.S_IFDIR | mode, st_uid=uid, st_gid=gid)
    return policy.component_allowed(
        Path(path),
        Path(executable),
        info,
        platform=platform,
        uid=501,
        admin_gid=80,
    )


@pytest.mark.parametrize("prefix", ["/opt/homebrew", "/usr/local"])
@pytest.mark.parametrize("owner", [0, 501])
def test_only_matching_admin_homebrew_directories_are_allowed(prefix, owner):
    executable = f"{prefix}/Cellar/git/1/bin/git"
    assert allowed(prefix, executable, uid=owner)
    assert allowed(prefix + "/Cellar", executable, uid=owner)
    assert allowed(prefix + "/Cellar/git/1", executable, uid=owner)


@pytest.mark.parametrize(
    "path,executable,options",
    [
        ("/opt/homebrew/Cellar", "/opt/homebrew/Cellar/git/1/bin/git", {"gid": 20}),
        ("/opt/homebrew/Cellar", "/opt/homebrew/Cellar/git/1/bin/git", {"uid": 502}),
        ("/opt/homebrew/Cellar", "/opt/homebrew/Cellar/git/1/bin/git", {"mode": 0o777}),
        (
            "/opt/homebrew/Cellar",
            "/opt/homebrew/Cellar/git/1/bin/git",
            {"platform": "linux"},
        ),
        ("/opt/homebrew", "/opt/homebrew/bin/custom", {}),
        ("/opt", "/opt/homebrew/Cellar/git/1/bin/git", {}),
        ("/usr", "/usr/local/Cellar/git/1/bin/git", {}),
        ("/opt/homebrew-fake/Cellar", "/opt/homebrew-fake/Cellar/git/bin/git", {}),
        ("/opt/homebrew/Cellar", "/usr/local/Cellar/git/1/bin/git", {}),
        ("/opt/homebrew/Cellar", "/opt/homebrew/Cellar-fake/git/bin/git", {}),
    ],
)
def test_exception_rejects_boundary_violations(path, executable, options):
    assert not allowed(path, executable, **options)


@pytest.mark.parametrize("mode", [0o775, 0o777, 0o664])
def test_homebrew_executable_files_never_get_directory_exception(mode):
    executable = Path("/opt/homebrew/Cellar/git/1/bin/git")
    info = SimpleNamespace(st_mode=stat.S_IFREG | mode, st_uid=501, st_gid=80)
    assert not policy.component_allowed(
        executable, executable, info, platform="darwin", uid=501, admin_gid=80
    )


def test_final_canonical_path_symlinks_are_rejected():
    executable = Path("/opt/homebrew/Cellar/git/1/bin/git")
    info = SimpleNamespace(st_mode=stat.S_IFLNK | 0o755, st_uid=501, st_gid=80)
    assert not policy.component_allowed(
        executable, executable, info, platform="darwin", uid=501, admin_gid=80
    )


def test_unexpected_admin_gid_does_not_enable_exception():
    path = Path("/opt/homebrew/Cellar")
    info = SimpleNamespace(st_mode=stat.S_IFDIR | 0o775, st_uid=501, st_gid=81)
    assert not policy.component_allowed(
        path, path / "git/1/bin/git", info, platform="darwin", uid=501, admin_gid=81
    )


def test_strict_system_executable_can_be_pinned_and_reverified():
    candidate = "/bin/ls"
    record = policy.pin(candidate)
    assert record["canonical"] == str(Path(candidate).resolve())
    assert len(record["sha256"]) == 64
    assert policy.verify(record) == record


@pytest.mark.parametrize("key,value", [("sha256", "0" * 64), ("canonical", "/bin/rm")])
def test_changed_identity_is_rejected(key, value):
    record = policy.pin("/bin/ls")
    record[key] = value
    with pytest.raises(ValueError, match="identity drifted"):
        policy.verify(record)


def test_paths_outside_fixed_roots_are_rejected(tmp_path):
    executable = tmp_path / "git"
    executable.write_text("harmless fixture")
    executable.chmod(0o755)
    with pytest.raises(ValueError, match="fixed trusted search roots"):
        policy.pin(str(executable))


def test_compiled_opt_alias_resolves_to_cellar_without_widening_canonical_roots(
    tmp_path, monkeypatch
):
    cellar = tmp_path / "Cellar"
    opt = tmp_path / "opt"
    cellar.mkdir()
    opt.mkdir()
    tool = cellar / "git"
    tool.write_bytes(b"read-only pin fixture")
    alias = opt / "git"
    alias.symlink_to(tool)
    monkeypatch.setattr(policy, "TRUSTED_ROOTS", (cellar,))
    monkeypatch.setattr(policy, "LOOKUP_ROOTS", (cellar, opt))
    # Isolate root selection/resolution from temporary-ancestor permissions.
    monkeypatch.setattr(policy, "component_allowed", lambda *args, **kwargs: True)
    record = policy.pin(str(alias))
    assert record["canonical"] == str(tool)
    assert policy.verify(record) == record
    alias.unlink()
    alias.write_bytes(b"a real opt file is not a Cellar target")
    with pytest.raises(ValueError, match="canonical executable.*fixed trusted roots"):
        policy.pin(str(alias))


def test_data_adapter_does_not_execute_tools_or_change_permissions():
    text = SOURCE.read_text()
    for token in ("subprocess", "os.system", "os.exec", "os.chmod", "os.chown"):
        assert token not in text
    assert "os.O_RDONLY | os.O_NOFOLLOW" in text
    assert "hashlib.sha256()" in text
