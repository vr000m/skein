#!/usr/bin/env python3
"""Generate an HTML dashboard + per-plan drill-down pages from a markdown dev-plan corpus.

See parser.md for the regex catalogue and status lexicon.
See SKILL.md for invocation and design notes.

Stdlib only — no external deps.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


# ---------------------------------------------------------------------------
# Constants — status lexicon + component heuristic + edge patterns
# ---------------------------------------------------------------------------

# Status lexicon. Order matters — first match wins.
# (regex, bucket, chip-colour-class)
STATUS_LEXICON: list[tuple[re.Pattern[str], str, str]] = [
    (
        re.compile(r"\bphases?\s+\d+\s*[-–]\s*\d+\s+(shipped|landed|complete)\b", re.I),
        "partial",
        "amber",
    ),
    (re.compile(r"\bphase\s+\d+\s+shipped\b", re.I), "partial", "amber"),
    (re.compile(r"\bpartially\s+shipped\b", re.I), "partial", "amber"),
    (re.compile(r"\bin\s+progress\b", re.I), "in-progress", "amber"),
    (re.compile(r"\bin\s+review\b", re.I), "in-progress", "amber"),
    (re.compile(r"\bnot\s+started\b", re.I), "planned", "blue"),
    (re.compile(r"\bplanned\b", re.I), "planned", "blue"),
    (re.compile(r"\bpaused\b", re.I), "paused", "grey"),
    (re.compile(r"\babandoned\b", re.I), "paused", "grey"),
    (re.compile(r"\bblocked\b", re.I), "blocked", "red"),
    (re.compile(r"\bshipped\b", re.I), "shipped", "green"),
    (re.compile(r"\bcomplete\b", re.I), "shipped", "green"),
    (re.compile(r"\bmerged\b", re.I), "shipped", "green"),
]

BUCKET_LABELS = {
    "shipped": "Shipped",
    "partial": "Partial",
    "in-progress": "In progress",
    "planned": "Planned",
    "paused": "Paused",
    "blocked": "Blocked",
    "stranded": "Stranded",
    "unknown": "Unknown",
}

# Component grouping. Each plan declares its own component in a `**Component**`
# bold-field header (parsed like `**Status**`). The dashboard groups by the exact,
# case-normalised string; plans with no field fall into UNCATEGORIZED. There is no
# slug heuristic and no config file — the plan markdown is the source of truth.
# See docs/dev_plans/20260521-feature-plan-view-skill.md "Component grouping".
UNCATEGORIZED = "(uncategorized)"

# Edge patterns. Order = precedence (highest first).
# Slugs may appear after a bare token, backtick, bracket, paren, OR inside a
# markdown link `[title](slug.md)` — the prefix snippet handles all forms.
_SLUG_PREFIX = r"(?:\[[^\]]+\]\(|[`\[(\s])*"
EDGE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "structural-fix-of",
        re.compile(
            rf"structurally\s+(?:fixed|addressed)\s+by\s*{_SLUG_PREFIX}(\d{{8}}-[\w-]+)",
            re.I,
        ),
    ),
    (
        "supersedes",
        re.compile(
            rf"(?:superseded\s+by|replaced\s+by|replaces)\s*{_SLUG_PREFIX}(\d{{8}}-[\w-]+)",
            re.I,
        ),
    ),
    (
        "tracked-in",
        re.compile(rf"tracked\s+(?:as|in)\s*{_SLUG_PREFIX}(\d{{8}}-[\w-]+)", re.I),
    ),
    (
        "follows",
        re.compile(
            rf"^\*\*Follows:?\*\*:?\s*{_SLUG_PREFIX}(\d{{8}}-[\w-]+)", re.I | re.M
        ),
    ),
    ("references", re.compile(r"(\d{8}-[\w-]+)\.md")),
]

PLAN_SLUG_RE = re.compile(r"^(\d{8})-([\w-]+)$")
PLAN_FILENAME_RE = re.compile(r"^\d{8}-[\w-]+\.md$")


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class Commit:
    sha: str
    date: str  # ISO8601
    subject: str

    @property
    def short_sha(self) -> str:
        return self.sha[:7]


@dataclass
class Edge:
    kind: str  # references | tracked-in | supersedes | structural-fix-of | follows
    target_slug: str  # slug of the referenced plan (no .md)


@dataclass(frozen=True)
class Section:
    """One ``## H2`` slice of a plan, for rich-mode section fanout.

    Frozen because instances are memoised in `_SECTIONS_CACHE` and shared across
    callers (and across tests in one process); immutability makes the shared
    reference safe.
    """

    section_id: str  # stable, unique slug (duplicate titles get -2, -3 suffixes)
    title: str
    markdown: str
    section_sha: str  # sha256 of markdown; gates per-section rich re-render


@dataclass
class Plan:
    slug: str  # filename minus .md (e.g. 20260506-feature-bot-harness-decoupling)
    path: Path
    raw: str
    sha256: str
    title: str = ""
    status_raw: str = ""
    bucket: str = "unknown"
    chip_colour: str = "amber"
    component: str = UNCATEGORIZED
    is_bug: bool = False
    pr_numbers: list[str] = field(default_factory=list)
    branch: str = ""
    created: str = ""
    last_touched: str = ""
    commits: list[Commit] = field(default_factory=list)
    edges_out: list[Edge] = field(default_factory=list)
    edges_in: list[tuple[str, str]] = field(default_factory=list)  # (kind, source_slug)
    phases_total: int = 0
    progress_done: int = 0
    progress_total: int = 0
    fixed_by: str | None = (
        None  # slug of the structural-fix-of plan if one exists and is shipped
    )
    render_sha: str = ""  # set by compute_render_shas after link_edges + apply_stranded

    def compute_render_sha(self) -> str:
        # Covers everything that affects this plan's rendered HTML:
        # own markdown, backfilled edges_in (corpus state), fixed_by pointer,
        # the (possibly stranded-recoloured) status bucket, AND the git-derived
        # fields embedded in the page (commit list, timeline SVG, created,
        # last_touched). Folding git fields in means a rebase/amend that changes
        # a commit subject or date — with the markdown bytes unchanged — shifts
        # render_sha, so the drift guard takes the "source changed, overwrite
        # freely" path instead of falsely flagging a hand-edit.
        parts = [
            self.sha256,
            "|edges_in=" + ",".join(f"{k}:{s}" for k, s in sorted(self.edges_in)),
            f"|fixed_by={self.fixed_by or ''}",
            f"|bucket={self.bucket}",
            "|commits="
            + ",".join(f"{c.sha}:{c.date}:{c.subject}" for c in self.commits),
            f"|created={self.created}",
            f"|last_touched={self.last_touched}",
        ]
        return hashlib.sha256("".join(parts).encode("utf-8")).hexdigest()


def compute_render_shas(plans: dict[str, "Plan"]) -> None:
    for p in plans.values():
        p.render_sha = p.compute_render_sha()


def corpus_sha(plans: dict[str, "Plan"]) -> str:
    """Stable hash of the whole corpus, used as the dashboard's drift-guard sha.

    Single source of truth so `render_dashboard` (which embeds it) and `main`
    (which passes it to the drift guard) cannot diverge — divergence would make
    the guard fire on every run. Requires `compute_render_shas` to have run.

    Derived from each plan's `render_sha`, which is a *superset* of what the
    dashboard renders (it also folds in commit subjects/dates the dashboard
    doesn't show). That makes this digest conservative: a commit-subject-only
    rewrite shifts corpus_sha and rewrites index.html even though its visible
    content is unchanged. We accept that on purpose — the alternative (hashing
    only dashboard-rendered fields) would reintroduce the triple-edit hazard
    findings #1/#7 removed, where a forgotten field makes the guard *falsely
    refuse*. Over-writing harmless gitignored output beats false refusals.
    """
    return hashlib.sha256(
        "".join(sorted(p.render_sha for p in plans.values())).encode("utf-8")
    ).hexdigest()


# ---------------------------------------------------------------------------
# Plan parsing
# ---------------------------------------------------------------------------


def _strip_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Return (frontmatter_dict, body) for YAML-like `---` blocks. PyYAML-free."""
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end != -1:
        fm_block, body = text[4:end], text[end + 5 :]
    elif text.endswith("\n---"):
        # Closing `---` at end-of-string with no trailing newline, including
        # frontmatter-only files. Body is then empty.
        fm_block, body = text[4 : len(text) - 4], ""
    else:
        return {}, text
    fm: dict[str, str] = {}
    for line in fm_block.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        fm[key.strip().lower()] = val.strip()
    return fm, body


def _find_title(body: str, frontmatter: dict[str, str]) -> str:
    if "title" in frontmatter:
        return frontmatter["title"]
    m = re.search(r"^#\s+(.+?)$", body, re.M)
    return m.group(1).strip() if m else "(untitled)"


_STATUS_LINE_RE = re.compile(r"^\*\*Status:?\*\*[:\s]*(.+?)$", re.M)
# Accepts BOTH `**Field:** value` (colon inside bold) AND the more common
# `**Field**: value` (colon outside bold, then space). The `[:\s]*` after `**`
# eats any trailing colon and whitespace so it doesn't leak into the value.
_FIELD_LINE_RE = re.compile(
    r"^\*\*(?P<field>[\w\s-]+?):?\*\*[:\s]*(?P<value>.+?)$", re.M
)


def _find_field_string(body: str, field: str, *, strip_backticks: bool = False) -> str:
    """Return a `**Field**` value (best effort). Tries inline-bold then field-table.

    Accepts both `**Field:** value` and `**Field**: value`, and the field-table
    row form `| **Field** | value |`. Used for Status, Component, Branch, Created.
    `strip_backticks=True` peels surrounding backticks off the value (e.g. a
    branch name written as `` `feat/foo` ``).
    """

    def _clean(value: str) -> str:
        value = value.strip()
        return value.strip("`") if strip_backticks else value

    inline = re.compile(rf"^\*\*{re.escape(field)}:?\*\*[:\s]*(.+?)$", re.M)
    m = inline.search(body)
    if m:
        return _clean(m.group(1))
    # Field-table style: `| **Field** | value |`
    needle, needle_colon = f"**{field}**", f"**{field}:**"
    for line in body.splitlines():
        if needle not in line and needle_colon not in line:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        for i, cell in enumerate(cells):
            if f"**{field}" in cell and i + 1 < len(cells):
                return _clean(cells[i + 1])
    return ""


def _find_status_string(body: str) -> str:
    """Return the raw status string (best effort)."""
    return _find_field_string(body, "Status")


def _normalise_component(raw: str) -> str:
    """Map a raw `**Component**` value to a group key. Empty -> UNCATEGORIZED.

    Case-normalised (lowercased) and whitespace-collapsed so `ASR`, `asr`, and
    `  asr ` group together. Multi-component plans (comma-separated) take the
    first listed value as the primary group (multi-membership is deferred)."""
    primary = raw.split(",")[0].strip()
    if not primary:
        return UNCATEGORIZED
    return " ".join(primary.lower().split())


def _classify_status(status_raw: str) -> tuple[str, str]:
    """Return (bucket, chip_colour) from the lexicon."""
    if not status_raw:
        return "unknown", "amber"
    for pattern, bucket, colour in STATUS_LEXICON:
        if pattern.search(status_raw):
            # Special case: "phases N-M shipped" — if N..M covers everything, treat as shipped.
            # Detected at render time via phases_total comparison; here keep partial.
            return bucket, colour
    return "unknown", "amber"


def _find_pr_numbers(text: str) -> list[str]:
    nums = re.findall(r"PRs?\s*#(\d+)", text)
    # Also catch standalone "#42" inside parens or after commas in a PR list
    pr_list_re = re.compile(r"PRs?\s*((?:#\d+[,\s]*)+)", re.I)
    for m in pr_list_re.finditer(text):
        nums.extend(re.findall(r"#(\d+)", m.group(1)))
    # Deduplicate, preserve order
    seen: set[str] = set()
    out = []
    for n in nums:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


def _find_edges(body: str) -> list[Edge]:
    edges: list[Edge] = []
    claimed: dict[str, str] = {}  # target -> highest-precedence kind already assigned
    for kind, pattern in EDGE_PATTERNS:
        for m in pattern.finditer(body):
            target = m.group(1)
            if target in claimed:
                continue
            claimed[target] = kind
            edges.append(Edge(kind=kind, target_slug=target))
    return edges


def _count_phases(body: str) -> int:
    return len(re.findall(r"^###\s+Phase\s+\d+", body, re.M))


_CHECKBOX_RE = re.compile(r"^\s*[-*]\s+\[([ x])\]", re.M)


def _count_checkboxes(body: str) -> tuple[int, int]:
    """Count Progress / Acceptance Criteria checkboxes."""
    # Restrict scan to sections named ## Progress / ## Acceptance Criteria
    section_re = re.compile(
        r"^##\s+(?:Progress|Acceptance Criteria)\b(.*?)(?=^##\s|\Z)",
        re.M | re.S | re.I,
    )
    done = total = 0
    for section in section_re.finditer(body):
        for box in _CHECKBOX_RE.finditer(section.group(1)):
            total += 1
            if box.group(1) == "x":
                done += 1
    return done, total


def _slug_is_bug(slug: str) -> bool:
    """True if the slug names a bug/fix plan (date prefix stripped)."""
    m = PLAN_SLUG_RE.match(slug)
    rest = m.group(2) if m else slug
    return rest.startswith(("bug-", "fix-")) or "-bug-" in rest or "-fix-" in rest


def parse_plan(path: Path) -> Plan:
    raw = path.read_text(encoding="utf-8", errors="replace")
    sha = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    frontmatter, body = _strip_frontmatter(raw)
    slug = path.stem
    is_bug = _slug_is_bug(slug)
    component = _normalise_component(_find_field_string(body, "Component"))
    status_raw = _find_status_string(body)
    bucket, chip = _classify_status(status_raw)
    phases_total = _count_phases(body)
    # Refinement: a "Phases N-M shipped" where M == phases_total means fully shipped.
    rng = re.search(
        r"phases?\s+(\d+)\s*[-–]\s*(\d+)\s+(shipped|landed|complete)", status_raw, re.I
    )
    if rng and phases_total and int(rng.group(2)) >= phases_total:
        bucket, chip = "shipped", "green"
    done, total = _count_checkboxes(body)
    # Drop self-references: a plan mentioning its own filename must not link to
    # itself (would render a "→ self / ← self" cross-reference pair). Filtering
    # here keeps it out of both edges_out and the edges_in backfill in link_edges.
    edges = [e for e in _find_edges(body) if e.target_slug != slug]
    pr_numbers = _find_pr_numbers(status_raw + " " + body[:2000])
    branch = frontmatter.get("branch") or _find_field_string(
        body, "Branch", strip_backticks=True
    )
    created = frontmatter.get("created") or _find_field_string(
        body, "Created", strip_backticks=True
    )
    return Plan(
        slug=slug,
        path=path,
        raw=raw,
        sha256=sha,
        title=_find_title(body, frontmatter),
        status_raw=status_raw or "(no status header)",
        bucket=bucket,
        chip_colour=chip,
        component=component,
        is_bug=is_bug,
        pr_numbers=pr_numbers,
        branch=branch,
        created=created,
        edges_out=edges,
        phases_total=phases_total,
        progress_done=done,
        progress_total=total,
    )


# ---------------------------------------------------------------------------
# README reconciliation (authoritative grouping if present)
# ---------------------------------------------------------------------------

README_BUCKETS = {
    "In Progress / Partially Shipped": "in-progress",
    "In Progress": "in-progress",
    "Partially Shipped": "partial",
    "Planned": "planned",
    "Shipped": "shipped",
    "Paused / Abandoned": "paused",
    "Paused": "paused",
    "Abandoned": "paused",
}


def parse_readme_grouping(readme_path: Path) -> dict[str, str]:
    """Return {slug -> bucket} from README tables, or {} if not present/parseable."""
    if not readme_path.exists():
        return {}
    text = readme_path.read_text(encoding="utf-8", errors="replace")
    grouping: dict[str, str] = {}
    current_bucket: str | None = None
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            current_bucket = README_BUCKETS.get(m.group(1).strip())
            continue
        if not current_bucket:
            continue
        # Match table rows that link to a .md plan
        link = re.search(r"\[(?P<title>[^\]]+)\]\((?P<href>[^)]+\.md)\)", line)
        if not link:
            continue
        href = link.group("href")
        slug = Path(href).stem
        # Only consider slugs that look like plan filenames
        if PLAN_SLUG_RE.match(slug):
            grouping[slug] = current_bucket
    return grouping


# ---------------------------------------------------------------------------
# Git collection
# ---------------------------------------------------------------------------


def _git(args: list[str], cwd: Path) -> str:
    try:
        out = subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        )
        return out.stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def collect_git_data(plan: Plan, repo_root: Path) -> None:
    """Populate plan.commits, plan.created (if empty), plan.last_touched."""
    try:
        rel = plan.path.relative_to(repo_root) if plan.path.is_absolute() else plan.path
    except ValueError:
        # Plan lives outside the discovered repo root (unusual layouts, symlinks).
        # Skip git enrichment rather than crash; the rest of the render still works.
        return
    raw = _git(
        ["log", "--follow", "--format=%H%x1f%aI%x1f%s", "--", str(rel)],
        cwd=repo_root,
    )
    commits: list[Commit] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\x1f", 2)
        if len(parts) != 3:
            continue
        commits.append(Commit(sha=parts[0], date=parts[1], subject=parts[2]))
    plan.commits = commits
    if commits:
        plan.last_touched = commits[0].date[:10]
        if not plan.created:
            plan.created = commits[-1].date[:10]


def git_head(repo_root: Path) -> str:
    return _git(["rev-parse", "HEAD"], cwd=repo_root).strip()


def find_repo_root(start: Path) -> Path:
    out = _git(["rev-parse", "--show-toplevel"], cwd=start).strip()
    return Path(out) if out else start


# ---------------------------------------------------------------------------
# Cross-edge backfill + stranded detection
# ---------------------------------------------------------------------------


def link_edges(plans: dict[str, Plan]) -> None:
    """Populate edges_in on each target plan, and set fixed_by where applicable."""
    # Reset derived state so the function is idempotent if called more than once
    # (e.g. tests, future watch mode). Without this, edges_in accumulates dupes.
    for p in plans.values():
        p.edges_in.clear()
        p.fixed_by = None
    for src_slug, src in plans.items():
        for edge in src.edges_out:
            target = plans.get(edge.target_slug)
            if target is None:
                continue
            target.edges_in.append((edge.kind, src_slug))
            # If the target is a bug plan and the source structurally fixes it AND source is shipped,
            # mark the bug as fixed_by the source.
            if (
                target.is_bug
                and edge.kind in ("structural-fix-of", "supersedes")
                and src.bucket == "shipped"
            ):
                target.fixed_by = src_slug


def apply_stranded(plans: Iterable[Plan], stale_days: int) -> None:
    """Re-colour in-progress / partial plans red if last-touched > stale_days ago."""
    if stale_days <= 0:
        return
    now = datetime.now(timezone.utc)
    for plan in plans:
        if plan.bucket not in ("in-progress", "partial"):
            continue
        if not plan.last_touched:
            continue
        try:
            last = datetime.fromisoformat(plan.last_touched).replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            continue
        age = (now - last).days
        if age > stale_days:
            plan.bucket = "stranded"
            plan.chip_colour = "red"


# ---------------------------------------------------------------------------
# Minimal markdown -> HTML
# ---------------------------------------------------------------------------

_INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
_BOLD_RE = re.compile(r"\*\*([^*\n]+)\*\*")
_ITALIC_RE = re.compile(r"(?<!\*)\*([^*\n]+)\*(?!\*)")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_SAFE_URL_RE = re.compile(r"^(?:https?://|mailto:|/|\.{0,2}/|[^:]*$)", re.I)


def _safe_href(url: str) -> str:
    # Block javascript:, data:, vbscript:, etc. Allow http(s), mailto, and
    # path-relative URLs. Returns "#" for anything else so the link still
    # renders as inert text rather than a working sink.
    return url if _SAFE_URL_RE.match(url) else "#"


_FENCE_RE = re.compile(r"^```(\w*)\s*$")


def _md_link(m: re.Match[str]) -> str:
    # `text` is already HTML-escaped by _inline_md, so the captured href and
    # label are too; only the attribute-delimiting quote still needs escaping.
    # Re-running html.escape here would double-encode '&' (e.g. a URL's
    # '&amp;' would become '&amp;amp;', which decodes back to a broken '&amp;').
    href = _safe_href(m.group(2)).replace('"', "&quot;")
    return f'<a href="{href}">{m.group(1)}</a>'


def _inline_md(text: str) -> str:
    text = html.escape(text, quote=False)
    # Mask inline-code spans with sentinels so the bold/italic/link rules below
    # can't reach inside them (e.g. `**x**` must stay literal, not turn bold).
    code_spans: list[str] = []

    def _stash_code(m: re.Match[str]) -> str:
        code_spans.append(m.group(1))
        return f"\x00CODE{len(code_spans) - 1}\x00"

    text = _INLINE_CODE_RE.sub(_stash_code, text)
    text = _BOLD_RE.sub(lambda m: f"<strong>{m.group(1)}</strong>", text)
    text = _ITALIC_RE.sub(lambda m: f"<em>{m.group(1)}</em>", text)
    text = _LINK_RE.sub(_md_link, text)
    text = re.sub(
        r"\x00CODE(\d+)\x00",
        lambda m: f"<code>{code_spans[int(m.group(1))]}</code>",
        text,
    )
    return text


def render_markdown(text: str) -> str:
    """Minimal markdown renderer — headings, paragraphs, lists, code fences, blockquotes, tables."""
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    in_para: list[str] = []

    def flush_para() -> None:
        if in_para:
            out.append(f"<p>{_inline_md(' '.join(in_para))}</p>")
            in_para.clear()

    while i < len(lines):
        line = lines[i]
        fence = _FENCE_RE.match(line)
        if fence:
            flush_para()
            lang = fence.group(1) or ""
            i += 1
            code_lines: list[str] = []
            while i < len(lines) and not _FENCE_RE.match(lines[i]):
                code_lines.append(lines[i])
                i += 1
            i += 1  # skip closing fence
            escaped = html.escape("\n".join(code_lines), quote=False)
            cls = f' class="lang-{lang}"' if lang else ""
            out.append(f"<pre><code{cls}>{escaped}</code></pre>")
            continue
        heading = re.match(r"^(#{1,6})\s+(.+?)\s*$", line)
        if heading:
            flush_para()
            level = len(heading.group(1))
            out.append(f"<h{level}>{_inline_md(heading.group(2))}</h{level}>")
            i += 1
            continue
        if line.startswith(">"):
            flush_para()
            quote_lines: list[str] = []
            while i < len(lines) and lines[i].startswith(">"):
                quote_lines.append(lines[i].lstrip(">").lstrip())
                i += 1
            out.append(f"<blockquote>{_inline_md(' '.join(quote_lines))}</blockquote>")
            continue
        if re.match(r"^\s*[-*+]\s+", line) or re.match(r"^\s*\d+\.\s+", line):
            flush_para()
            ordered = bool(re.match(r"^\s*\d+\.\s+", line))
            tag = "ol" if ordered else "ul"
            items: list[str] = []
            while i < len(lines) and (
                re.match(r"^\s*[-*+]\s+", lines[i])
                or re.match(r"^\s*\d+\.\s+", lines[i])
            ):
                item = re.sub(r"^\s*(?:[-*+]|\d+\.)\s+", "", lines[i])
                items.append(f"<li>{_inline_md(item)}</li>")
                i += 1
            out.append(f"<{tag}>{''.join(items)}</{tag}>")
            continue
        if (
            "|" in line
            and i + 1 < len(lines)
            and re.match(r"^\s*\|?[\s\-:|]+\|?\s*$", lines[i + 1])
        ):
            flush_para()
            header_cells = [c.strip() for c in line.strip().strip("|").split("|")]
            i += 2  # skip header + separator
            rows: list[list[str]] = []
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            thead = (
                "<tr>"
                + "".join(f"<th>{_inline_md(c)}</th>" for c in header_cells)
                + "</tr>"
            )
            tbody = "".join(
                "<tr>" + "".join(f"<td>{_inline_md(c)}</td>" for c in row) + "</tr>"
                for row in rows
            )
            out.append(f"<table><thead>{thead}</thead><tbody>{tbody}</tbody></table>")
            continue
        if not line.strip():
            flush_para()
            i += 1
            continue
        in_para.append(line.strip())
        i += 1
    flush_para()
    return "\n".join(out)


# ---------------------------------------------------------------------------
# HTML rendering — dashboard
# ---------------------------------------------------------------------------


def _esc(text: str) -> str:
    return html.escape(text or "", quote=True)


def _rich_href(slug: str) -> str:
    """HTML href to a plan's rich page. Single source for the deterministic
    `plan-<slug>.rich.html` link convention used by the dashboard card and the
    per-plan page header (slug HTML-escaped for the attribute context)."""
    return f"plan-{_esc(slug)}.rich.html"


def _chip(bucket: str, colour: str, extra: str = "") -> str:
    label = BUCKET_LABELS.get(bucket, bucket)
    return f'<span class="chip {colour}">{label}{extra}</span>'


def _edge_pill(edge: Edge, target_title: str | None) -> str:
    target_label = target_title or edge.target_slug
    return (
        f'<div class="edge">'
        f'<span class="label {edge.kind}">{edge.kind}</span>'
        f'<a href="plan-{edge.target_slug}.html">{_esc(target_label)}</a>'
        f"</div>"
    )


def _render_card(plan: Plan, plans: dict[str, Plan]) -> str:
    chip_extra = ""
    if plan.bucket == "unknown":
        chip_extra = " ?"
    chip = _chip(plan.bucket, plan.chip_colour, chip_extra)
    bug_chip = '<span class="chip bug">bug</span>' if plan.is_bug else ""
    progress = ""
    if plan.progress_total:
        progress = (
            f'<span class="chip grey">{plan.progress_done}/{plan.progress_total}</span>'
        )
    prs = ""
    if plan.pr_numbers:
        prs = " · " + " ".join(f"#{n}" for n in plan.pr_numbers[:3])
    edges_html = ""
    if plan.edges_out:
        edges_html = (
            '<div class="edges">'
            + "".join(
                _edge_pill(
                    e, plans[e.target_slug].title if e.target_slug in plans else None
                )
                for e in plan.edges_out[:5]
            )
            + "</div>"
        )
    fixed_by_html = ""
    if plan.fixed_by:
        fixer = plans[plan.fixed_by]
        fixed_by_html = (
            f'<div class="fixed-by">fixed by → '
            f'<a href="plan-{plan.fixed_by}.html">{_esc(fixer.title)}</a></div>'
        )
    return (
        f'<div class="card" data-bucket="{_esc(plan.bucket)}">'
        f'<div class="title"><a href="plan-{_esc(plan.slug)}.html">{_esc(plan.title)}</a></div>'
        f'<div class="meta-row">{chip}{bug_chip}{progress}<span>{_esc(plan.last_touched or plan.created or "—")}{prs}</span>'
        f'<a class="rich-link" href="{_rich_href(plan.slug)}" '
        f'title="rich view (generate with --rich)">rich →</a></div>'
        f"{edges_html}"
        f"{fixed_by_html}"
        f"</div>"
    )


_PLACEHOLDER_RE = re.compile(r"\{\{[A-Z0-9_]+\}\}")


def _apply_substitutions(template: str, substitutions: dict[str, str]) -> str:
    """Replace `{{KEY}}` placeholders, warning if the template and dict drift.

    Adding a rendered field requires editing the dataclass, the substitutions
    dict, and the HTML template in lockstep. This catches the common slip — a
    `{{PLACEHOLDER}}` in the template with no matching key — by scanning the
    *template* (not the output, so plan markdown that mentions `{{FOO}}` can't
    raise a false positive) and warning on stderr before shipping literal
    placeholder text into the HTML.
    """
    unmapped = sorted(set(_PLACEHOLDER_RE.findall(template)) - set(substitutions))
    if unmapped:
        print(
            f"warning: template placeholder(s) with no substitution: "
            f"{', '.join(unmapped)}",
            file=sys.stderr,
        )
    out = template
    for key, val in substitutions.items():
        out = out.replace(key, val)
    return out


def render_dashboard(
    plans: dict[str, Plan],
    plans_dir: Path,
    out_dir: Path,
    git_head_sha: str,
    template: str,
    readme_used: bool,
    script_path: str,
) -> str:
    # Group by component
    by_component: dict[str, list[Plan]] = {}
    for p in plans.values():
        by_component.setdefault(p.component, []).append(p)
    # Sort each component by last-touched desc
    for plans_in in by_component.values():
        plans_in.sort(key=lambda x: x.last_touched or x.created or "", reverse=True)

    # Order derived from the corpus: plan count desc, alphabetical tiebreak,
    # with UNCATEGORIZED forced last. No COMPONENT_ORDER constant.
    component_order = sorted(
        (c for c in by_component if c != UNCATEGORIZED),
        key=lambda c: (-len(by_component[c]), c),
    )
    if UNCATEGORIZED in by_component:
        component_order.append(UNCATEGORIZED)

    component_sections: list[str] = []
    for comp in component_order:
        plans_in = by_component.get(comp, [])
        if not plans_in:
            continue
        # bucket counts for this component
        bucket_counts: dict[str, int] = {}
        for p in plans_in:
            bucket_counts[p.bucket] = bucket_counts.get(p.bucket, 0) + 1
        bucket_summary = " · ".join(
            f"{n} {BUCKET_LABELS.get(b, b).lower()}" for b, n in bucket_counts.items()
        )
        cards = "\n".join(_render_card(p, plans) for p in plans_in)
        component_sections.append(
            f'<details class="component" open>'
            f'<summary>{_esc(comp)} <span style="font-weight:400;color:var(--fg-dim);font-size:12px;">'
            f"({len(plans_in)} · {bucket_summary})</span></summary>"
            f'<div class="grid">{cards}</div>'
            f"</details>"
        )

    # Summary chips — clickable buttons that filter cards by bucket.
    overall_counts: dict[str, int] = {}
    bucket_colour: dict[str, str] = {}
    for p in plans.values():
        overall_counts[p.bucket] = overall_counts.get(p.bucket, 0) + 1
        bucket_colour.setdefault(p.bucket, p.chip_colour)
    summary_chips = "".join(
        f'<button class="stat" type="button" data-bucket="{_esc(b)}" '
        f'title="Click to filter; click again to clear">'
        f'<span class="dot {bucket_colour[b]}"></span>'
        f"{n} {BUCKET_LABELS.get(b, b)}</button>"
        for b, n in sorted(overall_counts.items())
    )
    summary_chips += (
        '<button class="reset" type="button" title="Clear filters">clear</button>'
    )

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    now_short = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    # Shared helper so this embedded value matches the drift-guard sha in main().
    corpus_digest = corpus_sha(plans)
    plans_dir_short = str(plans_dir).replace(str(Path.home()), "~")
    readme_note = (
        " · status grouping from <code>README.md</code>"
        if readme_used
        else " · status from per-plan <code>**Status:**</code> headers"
    )

    substitutions = {
        "{{CORPUS_SHA}}": corpus_digest,
        "{{PLANS_DIR}}": str(plans_dir),
        "{{PLANS_DIR_SHORT}}": plans_dir_short,
        "{{SCRIPT_PATH}}": script_path,
        "{{GIT_HEAD}}": git_head_sha,
        "{{GIT_HEAD_SHORT}}": git_head_sha[:7] if git_head_sha else "—",
        "{{GENERATED_AT}}": now_iso,
        "{{GENERATED_AT_SHORT}}": now_short,
        "{{PLAN_COUNT}}": str(len(plans)),
        "{{SUMMARY_CHIPS}}": summary_chips,
        "{{COMPONENTS}}": "\n".join(component_sections),
        "{{README_NOTE}}": readme_note,
    }
    return _apply_substitutions(template, substitutions)


# ---------------------------------------------------------------------------
# HTML rendering — per-plan
# ---------------------------------------------------------------------------


def _render_timeline_svg(commits: list[Commit]) -> str:
    if not commits:
        return ""
    width = 720
    height = 32
    margin = 4
    if len(commits) == 1:
        positions = [width / 2]
    else:
        # Linear time scale from first commit to last
        try:
            dates = [datetime.fromisoformat(c.date) for c in commits]
        except ValueError:
            return ""
        t_min = min(dates).timestamp()
        t_max = max(dates).timestamp()
        span = max(t_max - t_min, 1.0)
        positions = [
            margin + (width - 2 * margin) * (d.timestamp() - t_min) / span
            for d in dates
        ]
    rects = "\n".join(
        f'<rect x="{pos - 2:.1f}" y="{margin}" width="4" height="{height - 2 * margin}">'
        f"<title>{_esc(c.short_sha)} · {_esc(c.date[:10])} · {_esc(c.subject)}</title>"
        f"</rect>"
        for pos, c in zip(positions, commits)
    )
    return (
        f'<svg class="timeline-strip" viewBox="0 0 {width} {height}" '
        f'width="100%" height="{height}">'
        f'<line x1="{margin}" y1="{height / 2}" x2="{width - margin}" y2="{height / 2}" />'
        f"{rects}"
        f"</svg>"
    )


def _render_edges_section(plan: Plan, plans: dict[str, Plan]) -> str:
    items: list[str] = []
    for edge in plan.edges_out:
        target = plans.get(edge.target_slug)
        target_html = (
            f'<a href="plan-{edge.target_slug}.html">{_esc(target.title)}</a>'
            if target
            else _esc(edge.target_slug)
        )
        items.append(
            f'<li><span class="label {edge.kind}">{edge.kind}</span>'
            f"<span>→ {target_html}</span></li>"
        )
    for kind, src_slug in plan.edges_in:
        src = plans.get(src_slug)
        src_html = (
            f'<a href="plan-{src_slug}.html">{_esc(src.title)}</a>'
            if src
            else _esc(src_slug)
        )
        items.append(
            f'<li><span class="label {kind}">incoming · {kind}</span>'
            f"<span>← {src_html}</span></li>"
        )
    if not items:
        return '<p style="color:var(--fg-muted);">No cross-references.</p>'
    return f"<ul>{''.join(items)}</ul>"


def render_plan_page(
    plan: Plan,
    plans: dict[str, Plan],
    git_head_sha: str,
    template: str,
    script_path: str,
    plans_dir_short: str,
) -> str:
    chip = _chip(
        plan.bucket, plan.chip_colour, " ?" if plan.bucket == "unknown" else ""
    )
    progress = ""
    if plan.progress_total:
        pct = (
            int(100 * plan.progress_done / plan.progress_total)
            if plan.progress_total
            else 0
        )
        progress = (
            f'<p style="color:var(--fg-dim);">Progress: '
            f"<strong>{plan.progress_done}/{plan.progress_total}</strong> ({pct}%) "
            f"checkboxes complete.</p>"
        )
    pr_links = ""
    if plan.pr_numbers:
        pr_links = "<span>PRs " + " ".join(f"#{n}" for n in plan.pr_numbers) + "</span>"
    branch_html = (
        f"<span>Branch <code>{_esc(plan.branch)}</code></span>" if plan.branch else ""
    )
    commit_list = (
        "\n".join(
            f'<li><span class="date">{_esc(c.date[:10])}</span>'
            f'<span class="sha">{_esc(c.short_sha)}</span>'
            f'<span class="subject">{_esc(c.subject)}</span></li>'
            for c in plan.commits[:50]
        )
        or "<li>(no commit history)</li>"
    )
    timeline_svg = _render_timeline_svg(plan.commits)
    edges_html = _render_edges_section(plan, plans)
    markdown_html = render_markdown(plan.raw)
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    now_short = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    source_path_short = str(plan.path).replace(str(Path.home()), "~")

    substitutions = {
        "{{SOURCE_SHA}}": plan.render_sha or plan.sha256,
        "{{SOURCE_SHA_SHORT}}": (plan.render_sha or plan.sha256)[:12],
        "{{SOURCE_PATH}}": source_path_short,
        "{{RICH_HREF}}": _rich_href(plan.slug),
        "{{SCRIPT_PATH}}": script_path,
        "{{PLANS_DIR_SHORT}}": plans_dir_short,
        "{{GIT_HEAD}}": git_head_sha,
        "{{GENERATED_AT}}": now_iso,
        "{{GENERATED_AT_SHORT}}": now_short,
        "{{TITLE}}": _esc(plan.title),
        "{{COMPONENT}}": _esc(plan.component),
        "{{STATUS_CHIP}}": chip,
        "{{STATUS_DETAIL}}": _esc(plan.status_raw),
        "{{PROGRESS}}": progress,
        "{{CREATED}}": _esc(plan.created or "—"),
        "{{LAST_TOUCHED}}": _esc(plan.last_touched or "—"),
        "{{PR_LINKS}}": pr_links,
        "{{BRANCH}}": branch_html,
        "{{EDGES}}": edges_html,
        "{{TIMELINE_SVG}}": timeline_svg,
        "{{COMMIT_LIST}}": commit_list,
        "{{MARKDOWN}}": markdown_html,
    }
    return _apply_substitutions(template, substitutions)


# ---------------------------------------------------------------------------
# Drift guard
# ---------------------------------------------------------------------------

_META_SHA_RE = re.compile(
    r'<meta\s+name="plan-view-source-sha256"\s+content="([0-9a-f]{64})"',
    re.I,
)

# Lines that vary by render-time and must be excluded from hand-edit detection.
_VOLATILE_LINE_RES = [
    re.compile(r'<meta\s+name="plan-view-generated-at"[^>]*>'),
    re.compile(r'<meta\s+name="plan-view-git-head"[^>]*>'),
    re.compile(r"<code>[^<]*UTC</code>"),
    re.compile(r"git <code>[0-9a-f]{7}</code>"),
]


def _stable_content(content: str) -> str:
    """Strip volatile render-time fields so hand-edit detection isn't fooled by timestamps."""
    out = content
    for pat in _VOLATILE_LINE_RES:
        out = pat.sub("", out)
    return out


def write_with_drift_guard(
    path: Path,
    new_content: str,
    source_sha: str,
    force: bool,
) -> tuple[bool, str]:
    """Write new_content to path unless drift is detected. Returns (wrote, message).

    Logic:
      - File doesn't exist → write.
      - File exists, embedded source-sha matches: compare *stable* (timestamp-stripped)
        content. If identical → no-op (idempotent). If different → hand-edit suspected;
        refuse unless --force.
      - File exists, embedded source-sha differs from new source-sha → source changed,
        overwrite freely.
    """
    if path.exists() and not force:
        existing = path.read_text(encoding="utf-8", errors="replace")
        existing_sha_m = _META_SHA_RE.search(existing[:4096])
        if existing_sha_m is None:
            # File exists in the output dir but isn't a plan-view artefact
            # (no embedded sha meta). Refuse to clobber — the user may have
            # an index.html, an architecture doc, or other content here.
            return (
                False,
                f"refused: {path.name} exists with no plan-view-source-sha256 meta "
                f"(likely a non-plan-view file); pass --force to overwrite",
            )
        if existing_sha_m.group(1) == source_sha:
            existing_stable = _stable_content(existing)
            new_stable = _stable_content(new_content)
            if existing_stable == new_stable:
                return (True, f"unchanged {path.name}")
            return (
                False,
                f"refused: {path.name} differs from regen but source markdown unchanged "
                f"(hand-edit suspected); pass --force to overwrite",
            )
        # else: file has plan-view meta but source-sha differs → source changed,
        # overwrite freely.
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new_content, encoding="utf-8")
    return True, f"wrote {path.name}"


# ---------------------------------------------------------------------------
# Rich manifest
# ---------------------------------------------------------------------------


_RICH_SHA_RE = re.compile(
    r'<meta name="plan-view-rich-source-sha256" content="([0-9a-f]{64})"'
)
_RICH_SECTION_SHA_RE = re.compile(
    r"<!--\s*plan-view-rich-section-sha256:\s*([0-9a-f]{64})\s*-->"
)
_H2_RE = re.compile(r"^## +(.+?)\s*$")
# Distinct from the markdown renderer's _FENCE_RE (which captures the language
# of a ``` fence): this one only detects fence *boundaries* (``` or ~~~, any
# length, optionally indented) so _h2_spans can skip H2s inside code blocks.
# The capture group is the full marker run so the caller can compare lengths
# (CommonMark: a closing fence must be the same char and at least as long as
# the opening one — a ``` line does not close a ```` block).
_SECTION_FENCE_RE = re.compile(r"^\s*((`{3,})|(~{3,}))")

# Plans larger than this OR with more H2s than this get section-fanout.
SECTIONS_CHAR_THRESHOLD = 25_000
SECTIONS_H2_THRESHOLD = 10


def _h2_spans(text: str) -> list[tuple[int, str]]:
    """Return (start_offset, title) for each top-level ``## H2`` heading.

    Lines inside fenced code blocks (``` ``` ``` or ``~~~``) are skipped so a
    ``## ...`` line within a code fence is not mistaken for a section boundary.
    Fence state toggles on the fence character (backtick vs tilde) so a tilde
    fence inside a backtick block doesn't prematurely close it, and the closing
    fence must be at least as long as the opening run (CommonMark) so a ``` line
    does not close a ```` block.
    """
    spans: list[tuple[int, str]] = []
    in_fence = False
    fence_char = ""
    fence_len = 0
    offset = 0
    for line in text.splitlines(keepends=True):
        fence_m = _SECTION_FENCE_RE.match(line)
        if fence_m:
            marker_run = fence_m.group(1)
            marker, run_len = marker_run[0], len(marker_run)
            if not in_fence:
                in_fence, fence_char, fence_len = True, marker, run_len
                offset += len(line)
                continue
            if marker == fence_char and run_len >= fence_len:
                in_fence, fence_char, fence_len = False, "", 0
                offset += len(line)
                continue
            # Same-style-but-shorter or different-char fence line while open:
            # it's content, not a boundary — fall through to skip it as in-fence.
            offset += len(line)
            continue
        if not in_fence:
            h2_m = _H2_RE.match(line)
            if h2_m:
                spans.append((offset, h2_m.group(1).strip()))
        offset += len(line)
    return spans


def _existing_rich_sha(path: Path) -> str | None:
    if not path.exists():
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    m = _RICH_SHA_RE.search(text)
    return m.group(1) if m else None


def _existing_section_sha(path: Path) -> str | None:
    if not path.exists():
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    m = _RICH_SECTION_SHA_RE.search(text)
    return m.group(1) if m else None


def _slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "section"


# Memoise splits per (slug, markdown sha) so build_rich_manifest and
# assemble_rich_sections — which each call split_into_sections for the same
# plans, possibly in separate CLI runs but commonly together in tests — share
# one deterministic result instead of recomputing. Keyed by content sha, so a
# stale entry can never be served after the markdown changes.
_SECTIONS_CACHE: dict[tuple[str, str], list[Section]] = {}


def split_into_sections(plan: Plan) -> list[Section]:
    """Split a plan's markdown on `## H2` boundaries.

    Returns an ordered list of `Section`. Content before the first H2 becomes
    `section_id="preamble"`. Duplicate slugs get `-2`, `-3` suffixes for stable,
    unique ids. H2 lines inside fenced code blocks are not section boundaries.
    """
    cache_key = (plan.slug, plan.sha256)
    cached = _SECTIONS_CACHE.get(cache_key)
    if cached is not None:
        # Return a fresh list so a caller mutating the list (append/clear) can't
        # corrupt the cached entry; the Section elements are frozen.
        return list(cached)

    spans = _h2_spans(plan.raw)
    sections: list[Section] = []
    seen: dict[str, int] = {}

    def _push(section_id: str, title: str, body: str) -> None:
        base = section_id
        n = seen.get(base, 0) + 1
        seen[base] = n
        if n > 1:
            section_id = f"{base}-{n}"
        sections.append(
            Section(
                section_id=section_id,
                title=title,
                markdown=body,
                section_sha=hashlib.sha256(body.encode("utf-8")).hexdigest(),
            )
        )

    if not spans:
        _push("body", "Body", plan.raw)
        _SECTIONS_CACHE[cache_key] = sections
        return list(sections)

    preamble = plan.raw[: spans[0][0]]
    if preamble.strip():
        _push("preamble", "(preamble)", preamble.strip("\n") + "\n")

    for i, (start, title) in enumerate(spans):
        end = spans[i + 1][0] if i + 1 < len(spans) else len(plan.raw)
        body = plan.raw[start:end]
        _push(_slugify(title), title, body)

    _SECTIONS_CACHE[cache_key] = sections
    return list(sections)


def _needs_sections(plan: Plan) -> bool:
    h2_count = len(_h2_spans(plan.raw))
    return len(plan.raw) > SECTIONS_CHAR_THRESHOLD or h2_count > SECTIONS_H2_THRESHOLD


def build_rich_manifest(
    plans: dict[str, Plan],
    plans_dir: Path,
    out_dir: Path,
    skill_dir: Path,
) -> list[dict]:
    """Manifest of plans needing rich-mode (LLM-rendered) regeneration.

    Two strategies per plan:
    - **single**: one subagent renders the whole plan (small plans).
    - **sections**: dice on H2 boundaries; one subagent per section in
      parallel; assembly stitches fragments via `tabs.html`. Used when
      `_needs_sections(plan)` is true.

    Rich pages are gated on the plan's own markdown sha (NOT the render_sha
    that folds in corpus state) — the LLM input is single plan markdown, so
    corpus changes around it shouldn't trigger expensive re-renders. Section
    fragments are gated on per-section sha, so editing one section only
    re-renders that section.
    """
    entries: list[dict] = []
    widgets_dir = skill_dir / "_widgets"
    fragments_dir = out_dir / "_fragments"

    for slug, plan in sorted(plans.items()):
        output_path = out_dir / f"plan-{slug}.rich.html"
        existing = _existing_rich_sha(output_path)

        if not _needs_sections(plan):
            status = "cached" if existing == plan.sha256 else "pending"
            entries.append(
                {
                    "slug": slug,
                    "strategy": "single",
                    "title": plan.title,
                    "status": status,
                    "source_path": str(plan.path),
                    "source_md_sha": plan.sha256,
                    "output_path": str(output_path),
                    "widget_catalogue": str(widgets_dir / "README.md"),
                    "bucket": plan.bucket,
                    "existing_rich_sha": existing,
                }
            )
            continue

        # sections strategy
        sections = split_into_sections(plan)
        section_entries: list[dict] = []
        all_cached = True
        for sec in sections:
            frag_path = fragments_dir / f"{slug}__{sec.section_id}.html"
            existing_sec = _existing_section_sha(frag_path)
            sec_status = "cached" if existing_sec == sec.section_sha else "pending"
            if sec_status == "pending":
                all_cached = False
            section_entries.append(
                {
                    "section_id": sec.section_id,
                    "title": sec.title,
                    "section_md_sha": sec.section_sha,
                    "markdown_excerpt": sec.markdown[:200],
                    "fragment_path": str(frag_path),
                    "status": sec_status,
                    "existing_section_sha": existing_sec,
                }
            )

        # State machine for sections-strategy plans:
        #   cached  — all fragments fresh AND assembled .rich.html embeds matching sha
        #   partial — some fragments still pending; the harness must render them
        #   pending — all fragments fresh, but assembled .rich.html is missing/stale;
        #             the harness must run `--rich-assemble` to stitch them
        if all_cached and existing == plan.sha256:
            aggregate_status = "cached"
        elif not all_cached:
            aggregate_status = "partial"
        else:
            aggregate_status = "pending"
        entries.append(
            {
                "slug": slug,
                "strategy": "sections",
                "title": plan.title,
                "aggregate_status": aggregate_status,
                "source_path": str(plan.path),
                "source_md_sha": plan.sha256,
                "output_path": str(output_path),
                "fragments_dir": str(fragments_dir),
                "widget_catalogue": str(widgets_dir / "README.md"),
                "bucket": plan.bucket,
                "existing_rich_sha": existing,
                "sections": section_entries,
            }
        )
    return entries


def assemble_rich_sections(
    plans: dict[str, Plan],
    plans_dir: Path,
    out_dir: Path,
    skill_dir: Path,
) -> tuple[int, int, list[str]]:
    """Stitch section fragments into final rich HTML for strategy=sections plans.

    Returns (assembled, skipped_missing, missing_descriptions).
    """
    tabs_template = (skill_dir / "_widgets" / "tabs.html").read_text(encoding="utf-8")
    # Strip ALL leading documentation comments — their body would otherwise be
    # exposed when a fragment's own sha-comment `-->` closes the outer comment
    # early (HTML comments don't nest).
    while True:
        stripped = re.sub(
            r"\A\s*<!--.*?-->\s*", "", tabs_template, count=1, flags=re.DOTALL
        )
        if stripped == tabs_template:
            break
        tabs_template = stripped
    base_css = (skill_dir / "_widgets" / "base.css").read_text(encoding="utf-8")
    fragments_dir = out_dir / "_fragments"

    assembled = 0
    skipped = 0
    missing: list[str] = []

    for slug, plan in sorted(plans.items()):
        if not _needs_sections(plan):
            continue
        sections = split_into_sections(plan)
        # Verify all fragments present + sha-current
        frag_contents: list[tuple[Section, str]] = []
        any_missing = False
        for sec in sections:
            frag_path = fragments_dir / f"{slug}__{sec.section_id}.html"
            existing_sec = _existing_section_sha(frag_path)
            if existing_sec != sec.section_sha:
                any_missing = True
                missing.append(
                    f"{slug}: {sec.section_id} "
                    f"(have={existing_sec[:8] if existing_sec else 'none'}, "
                    f"need={sec.section_sha[:8]})"
                )
                continue
            frag_contents.append((sec, frag_path.read_text(encoding="utf-8")))

        if any_missing:
            skipped += 1
            continue

        # Build tabs scaffold
        tabs_id = f"plan-{slug}"
        tab_bar_html = []
        tab_panels_html = []
        rules = []
        for i, (sec, frag) in enumerate(frag_contents):
            checked = " checked" if i == 0 else ""
            sid = sec.section_id
            tab_bar_html.append(
                f'<input type="radio" name="tabs-{tabs_id}" '
                f'id="tab-{tabs_id}-{sid}" class="tab-radio"{checked}>\n'
                f'<label for="tab-{tabs_id}-{sid}" class="tab-label">'
                f"{html.escape(sec.title)}</label>"
            )
            tab_panels_html.append(
                f'<div class="tab-panel" data-slot="{sid}">\n{frag}\n</div>'
            )
            rules.append(
                f'.tabs[data-tabs-id="{tabs_id}"]:has(#tab-{tabs_id}-{sid}:checked) '
                f'.tab-panel[data-slot="{sid}"] {{ display: block; }}'
            )

        tabs_html = _apply_substitutions(
            tabs_template,
            {
                "{{TABS_ID}}": tabs_id,
                "{{TAB_BAR_HTML}}": "\n".join(tab_bar_html),
                "{{TAB_PANELS_HTML}}": "\n".join(tab_panels_html),
                "{{PANEL_VISIBILITY_RULES}}": "\n    ".join(rules),
            },
        )

        title = html.escape(plan.title or slug)
        sha_short = plan.sha256[:12]
        rel_source = plan.path.name
        bucket_chip = _chip(plan.bucket, plan.chip_colour)
        page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="plan-view-rich-source-sha256" content="{plan.sha256}">
<meta name="plan-view-rich-strategy" content="sections">
<meta name="plan-view-rich-section-count" content="{len(frag_contents)}">
<title>{title} — rich view</title>
<link rel="preconnect" href="https://rsms.me/">
<link rel="stylesheet" href="https://rsms.me/inter/inter.css">
<style>
{base_css}
body {{ max-width: 1200px; margin: 0 auto; padding: 32px 24px 80px; }}
header.plan-hero {{ padding: 24px 0; border-bottom: 1px solid var(--border); margin-bottom: 24px; }}
header.plan-hero h1 {{ margin: 8px 0 12px; }}
header.plan-hero .meta {{ color: var(--fg-muted); font-size: 14px; }}
.tab-bar {{ display: flex; flex-wrap: wrap; gap: 4px; border-bottom: 1px solid var(--border); margin-bottom: 24px; }}
footer.plan-foot {{ margin-top: 64px; padding-top: 16px; border-top: 1px solid var(--border); color: var(--fg-muted); font-size: 13px; }}
</style>
</head>
<body>
<header class="plan-hero">
  <div class="meta"><a href="index.html">← Plan View</a> · <a href="plan-{_esc(slug)}.html">deterministic view</a></div>
  <div class="meta">plan-view · rich · {html.escape(slug)}</div>
  <h1>{title}</h1>
  <div class="meta">{bucket_chip} · Source sha <code>{sha_short}</code> · {len(frag_contents)} sections (assembled from fragments)</div>
</header>

{tabs_html}

<footer class="plan-foot">
  Rich view · assembled from {len(frag_contents)} section fragments · source sha <code>{sha_short}</code>.
  Source of truth: <code>{html.escape(rel_source)}</code>.
</footer>
</body>
</html>
"""
        (out_dir / f"plan-{slug}.rich.html").write_text(page, encoding="utf-8")
        assembled += 1

    return assembled, skipped, missing


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Generate an HTML dashboard from a dev-plan corpus.",
    )
    ap.add_argument(
        "plans_dir", type=Path, help="Directory containing yyyymmdd-*.md plans."
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output directory (default: <plans-dir>/../_plan_view/)",
    )
    ap.add_argument(
        "--force", action="store_true", help="Overwrite even if drift is detected."
    )
    ap.add_argument(
        "--stale-days",
        type=int,
        default=30,
        help="In-progress plans older than this become Stranded (default 30).",
    )
    ap.add_argument(
        "--gitignore",
        action="store_true",
        help="Write a .gitignore with '*' in the output dir.",
    )
    ap.add_argument(
        "--rich",
        action="store_true",
        help=(
            "Emit _rich_manifest.json listing plans whose rich HTML (LLM-rendered "
            "single-plan view) needs regeneration. Large plans get strategy=sections "
            "with one entry per H2 — agent spawns N subagents in parallel. See "
            "SKILL.md '--rich workflow'."
        ),
    )
    ap.add_argument(
        "--rich-assemble",
        action="store_true",
        dest="rich_assemble",
        help=(
            "Stitch section fragments into final plan-<slug>.rich.html for "
            "strategy=sections plans. Run after the agent harness has produced "
            "all fragments listed in the manifest."
        ),
    )
    args = ap.parse_args(argv)

    plans_dir: Path = args.plans_dir.resolve()
    if not plans_dir.is_dir():
        print(f"error: {plans_dir} is not a directory", file=sys.stderr)
        return 2

    out_dir: Path = (args.out or (plans_dir.parent / "_plan_view")).resolve()
    repo_root = find_repo_root(plans_dir)

    # Load skill assets
    skill_dir = Path(__file__).resolve().parent
    dashboard_template = (skill_dir / "template.html").read_text(encoding="utf-8")
    plan_template = (skill_dir / "plan-template.html").read_text(encoding="utf-8")

    # Parse all plans
    plans: dict[str, Plan] = {}
    for path in sorted(plans_dir.glob("*.md")):
        if not PLAN_FILENAME_RE.match(path.name):
            continue
        plan = parse_plan(path)
        plans[plan.slug] = plan

    if not plans:
        print(
            f"error: no plan files matching yyyymmdd-*.md found in {plans_dir}",
            file=sys.stderr,
        )
        return 2

    # README reconciliation
    readme_grouping = parse_readme_grouping(plans_dir / "README.md")
    readme_used = bool(readme_grouping)
    if readme_used:
        for slug, bucket in readme_grouping.items():
            plan = plans.get(slug)
            if plan is None:
                continue
            plan.bucket = bucket
            plan.chip_colour = {
                "shipped": "green",
                "partial": "amber",
                "in-progress": "amber",
                "planned": "blue",
                "paused": "grey",
                "blocked": "red",
            }.get(bucket, "amber")

    # Git
    git_head_sha = git_head(repo_root)
    for plan in plans.values():
        collect_git_data(plan, repo_root)

    # Stranded detection
    apply_stranded(plans.values(), args.stale_days)
    # Note: link_edges runs immediately below; compute_render_shas must come after.

    # Edge linking
    link_edges(plans)
    compute_render_shas(plans)

    # Render
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.gitignore:
        (out_dir / ".gitignore").write_text("*\n", encoding="utf-8")

    # Compute script_path relative to repo_root once — kept harness-neutral so
    # the generated HTML's "regenerate with …" footer points at the actual
    # location (e.g. .claude/skills/plan-view/generate.py for Claude users,
    # .codex/skills/plan-view/generate.py for Codex users).
    try:
        script_path = str(Path(__file__).resolve().relative_to(repo_root))
    except ValueError:
        script_path = str(Path(__file__).resolve())
    plans_dir_short = str(plans_dir).replace(str(Path.home()), "~")

    # Dashboard
    dashboard_html = render_dashboard(
        plans,
        plans_dir,
        out_dir,
        git_head_sha,
        dashboard_template,
        readme_used,
        script_path,
    )
    dashboard_corpus_sha = corpus_sha(plans)
    refused = 0
    written = 0
    wrote, msg = write_with_drift_guard(
        out_dir / "index.html",
        dashboard_html,
        dashboard_corpus_sha,
        args.force,
    )
    if wrote:
        written += 1
        print(msg)
    else:
        refused += 1
        print(msg, file=sys.stderr)

    for plan in plans.values():
        page_html = render_plan_page(
            plan, plans, git_head_sha, plan_template, script_path, plans_dir_short
        )
        wrote, msg = write_with_drift_guard(
            out_dir / f"plan-{plan.slug}.html",
            page_html,
            plan.render_sha,
            args.force,
        )
        if wrote:
            written += 1
        else:
            refused += 1
            print(msg, file=sys.stderr)

    print(f"\n{len(plans)} plans · wrote {written} file(s) · refused {refused}")
    print(f"open: file://{out_dir}/index.html")

    if args.rich:
        rich_entries = build_rich_manifest(plans, plans_dir, out_dir, skill_dir)
        (out_dir / "_fragments").mkdir(exist_ok=True)
        manifest_path = out_dir / "_rich_manifest.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "schema_version": 2,
                    "generated_at": datetime.now(timezone.utc)
                    .isoformat()
                    .replace("+00:00", "Z"),
                    "git_head": git_head_sha,
                    "widget_catalogue": str(skill_dir / "_widgets"),
                    "fragments_dir": str(out_dir / "_fragments"),
                    "entries": rich_entries,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        single_entries = [e for e in rich_entries if e["strategy"] == "single"]
        section_entries = [e for e in rich_entries if e["strategy"] == "sections"]
        single_pending = sum(1 for e in single_entries if e["status"] == "pending")
        single_cached = sum(1 for e in single_entries if e["status"] == "cached")
        section_pending_frags = sum(
            sum(1 for s in e["sections"] if s["status"] == "pending")
            for e in section_entries
        )
        section_total_frags = sum(len(e["sections"]) for e in section_entries)
        section_plans_pending = sum(
            1 for e in section_entries if e["aggregate_status"] != "cached"
        )

        print(
            f"\nrich manifest: {manifest_path}"
            f"\n  single-strategy: {single_pending} pending · {single_cached} cached "
            f"({len(single_entries)} plans)"
            f"\n  sections-strategy: {section_pending_frags}/{section_total_frags} "
            f"fragment(s) pending across {section_plans_pending}/{len(section_entries)} "
            f"plan(s)"
        )
        if single_pending or section_pending_frags:
            print(
                "  next: agent harness reads _rich_manifest.json. For each strategy=single "
                "pending entry, spawn one subagent → writes to entry.output_path. For each "
                "strategy=sections entry with pending sections, spawn one subagent per "
                "pending section in parallel → each writes its fragment to "
                "section.fragment_path. Then run `--rich-assemble` to stitch fragments "
                "into final plan-<slug>.rich.html. See SKILL.md '--rich workflow'."
            )

    if args.rich_assemble:
        assembled, skipped, missing = assemble_rich_sections(
            plans, plans_dir, out_dir, skill_dir
        )
        print(
            f"\nrich-assemble: stitched {assembled} plan(s); skipped {skipped} "
            f"(missing/stale fragments)"
        )
        if missing:
            print("  missing or stale fragments:")
            for m in missing[:20]:
                print(f"    {m}")
            if len(missing) > 20:
                print(f"    … and {len(missing) - 20} more")

    return 0 if refused == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
