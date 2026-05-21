"""Drift-guard behaviour: first write, idempotent re-write, hand-edit refusal,
source-change overwrite."""

from pathlib import Path

import generate as G


def _build(sha: str, body_extra: str = "") -> str:
    return (
        f'<html><head><meta name="plan-view-source-sha256" content="{sha}">'
        f'<meta name="plan-view-generated-at" content="2026-01-01T00:00:00Z">'
        f"</head><body>{body_extra}</body></html>"
    )


def test_refuses_to_clobber_file_without_plan_view_meta(tmp_path: Path) -> None:
    # Pre-existing file with no plan-view sha (e.g. a hand-authored index.html
    # the user dropped into the output dir) must not be silently overwritten.
    target = tmp_path / "index.html"
    target.write_text(
        "<html><body>my hand-authored doc, not from plan-view</body></html>",
        encoding="utf-8",
    )
    wrote, msg = G.write_with_drift_guard(
        target, _build("a" * 64), "a" * 64, force=False
    )
    assert wrote is False
    assert "no plan-view-source-sha256" in msg
    # Original content preserved
    assert "my hand-authored doc" in target.read_text(encoding="utf-8")


def test_force_overwrites_file_without_plan_view_meta(tmp_path: Path) -> None:
    target = tmp_path / "index.html"
    target.write_text("<html><body>pre-existing</body></html>", encoding="utf-8")
    wrote, _ = G.write_with_drift_guard(target, _build("a" * 64), "a" * 64, force=True)
    assert wrote is True
    assert "plan-view-source-sha256" in target.read_text(encoding="utf-8")


def test_write_when_missing(tmp_path: Path) -> None:
    p = tmp_path / "out.html"
    wrote, msg = G.write_with_drift_guard(p, _build("a" * 64), "a" * 64, force=False)
    assert wrote
    assert p.exists()
    assert "wrote" in msg


def test_idempotent_no_op(tmp_path: Path) -> None:
    p = tmp_path / "out.html"
    G.write_with_drift_guard(p, _build("a" * 64), "a" * 64, force=False)
    wrote, msg = G.write_with_drift_guard(
        p, _build("a" * 64), "a" * 64, force=False
    )  # content stable; only timestamp would differ if it varied
    assert wrote
    assert "unchanged" in msg


def test_hand_edit_refused(tmp_path: Path) -> None:
    p = tmp_path / "out.html"
    G.write_with_drift_guard(p, _build("a" * 64, "<p>orig</p>"), "a" * 64, force=False)
    # Same sha, but new render differs from existing → looks like a hand-edit
    new_content = _build("a" * 64, "<p>NEW</p>")
    wrote, msg = G.write_with_drift_guard(p, new_content, "a" * 64, force=False)
    assert not wrote
    assert "refused" in msg
    # File unchanged
    assert "orig" in p.read_text(encoding="utf-8")


def test_force_overrides_refusal(tmp_path: Path) -> None:
    p = tmp_path / "out.html"
    G.write_with_drift_guard(p, _build("a" * 64, "<p>orig</p>"), "a" * 64, force=False)
    new_content = _build("a" * 64, "<p>NEW</p>")
    wrote, _ = G.write_with_drift_guard(p, new_content, "a" * 64, force=True)
    assert wrote
    assert "NEW" in p.read_text(encoding="utf-8")


def test_source_change_overwrites_freely(tmp_path: Path) -> None:
    p = tmp_path / "out.html"
    G.write_with_drift_guard(p, _build("a" * 64, "<p>v1</p>"), "a" * 64, force=False)
    # New sha → source changed; should overwrite without --force
    wrote, _ = G.write_with_drift_guard(
        p, _build("b" * 64, "<p>v2</p>"), "b" * 64, force=False
    )
    assert wrote
    assert "v2" in p.read_text(encoding="utf-8")
