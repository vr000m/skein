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

# Component heuristic — patterns matched against the filename slug (date prefix stripped).
COMPONENT_PATTERNS: list[tuple[str, list[str]]] = [
    (
        "bot-harness",
        [
            "bot",
            "harness-decoupling",
            "harness-digest",
            "cron",
            "scheduled",
            "worker",
            "wedge",
        ],
    ),
    (
        "asr",
        [
            "asr",
            "whisper",
            "parakeet",
            "diarization",
            "transcript-quality",
            "segmentation",
            "hallucination",
        ],
    ),
    (
        "data-processing",
        [
            "digest",
            "topic",
            "collation",
            "map-reduce",
            "query",
            "action-item",
            "ap-",
            "classify",
            "reprocess",
            "merge",
            "dedup",
            "answer-cache",
            "ask-",
            "ask_",
            "extensible-koda-ask",
            "harness-ask",
            "cmdk",
            "cmd-k",
        ],
    ),
    (
        "web-ui",
        ["ui", "web", "admin", "live-call", "calendar", "ux", "polish", "redesign"],
    ),
    ("benchmark", ["benchmark", "lmstudio", "gemma"]),
    (
        "infra",
        [
            "airpods",
            "recovery",
            "flush",
            "legacy",
            "id-rekey",
            "id-fork",
            "utc",
            "markdown-headers",
        ],
    ),
    ("meta", ["followup", "followon", "trend-analysis"]),
]

COMPONENT_ORDER = [
    "bot-harness",
    "asr",
    "data-processing",
    "web-ui",
    "benchmark",
    "infra",
    "meta",
    "other",
]

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
    component: str = "other"
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
        # and the (possibly stranded-recoloured) status bucket.
        parts = [
            self.sha256,
            "|edges_in=" + ",".join(f"{k}:{s}" for k, s in sorted(self.edges_in)),
            f"|fixed_by={self.fixed_by or ''}",
            f"|bucket={self.bucket}",
        ]
        return hashlib.sha256("".join(parts).encode("utf-8")).hexdigest()


def compute_render_shas(plans: dict[str, "Plan"]) -> None:
    for p in plans.values():
        p.render_sha = p.compute_render_sha()


# ---------------------------------------------------------------------------
# Plan parsing
# ---------------------------------------------------------------------------


def _strip_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Return (frontmatter_dict, body) for YAML-like `---` blocks. PyYAML-free."""
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}, text
    fm_block = text[4:end]
    body = text[end + 5 :]
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


_STATUS_LINE_RE = re.compile(r"^\*\*Status:?\*\*\s*(.+?)$", re.M)
_FIELD_LINE_RE = re.compile(r"^\*\*(?P<field>[\w\s-]+?):?\*\*\s*(?P<value>.+?)$", re.M)


def _find_status_string(body: str) -> str:
    """Return the raw status string (best effort). Tries inline-bold then field-table."""
    m = _STATUS_LINE_RE.search(body)
    if m:
        return m.group(1).strip()
    # Field-table style: `| **Status** | value |`
    for line in body.splitlines():
        if "**Status**" not in line and "**Status:**" not in line:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        for i, cell in enumerate(cells):
            if "**Status" in cell and i + 1 < len(cells):
                return cells[i + 1].strip()
    return ""


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


def _find_field(body: str, name: str) -> str:
    """Find a `**Name:** value` or field-table style field."""
    pattern = re.compile(rf"^\*\*{re.escape(name)}:?\*\*\s*(.+?)$", re.M)
    m = pattern.search(body)
    if m:
        return m.group(1).strip().strip("`")
    # Field-table style
    for line in body.splitlines():
        if f"**{name}**" not in line:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        for i, cell in enumerate(cells):
            if f"**{name}" in cell and i + 1 < len(cells):
                return cells[i + 1].strip().strip("`")
    return ""


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


def _classify_component(slug: str) -> tuple[str, bool]:
    """Return (component, is_bug)."""
    # Strip date prefix: 20260506-feature-bot-... -> feature-bot-...
    m = PLAN_SLUG_RE.match(slug)
    rest = m.group(2) if m else slug
    is_bug = rest.startswith(("bug-", "fix-")) or "-bug-" in rest or "-fix-" in rest
    for component, patterns in COMPONENT_PATTERNS:
        for pat in patterns:
            if pat in rest:
                return component, is_bug
    return "other", is_bug


def parse_plan(path: Path) -> Plan:
    raw = path.read_text(encoding="utf-8", errors="replace")
    sha = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    frontmatter, body = _strip_frontmatter(raw)
    slug = path.stem
    component, is_bug = _classify_component(slug)
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
    edges = _find_edges(body)
    pr_numbers = _find_pr_numbers(status_raw + " " + body[:2000])
    branch = frontmatter.get("branch") or _find_field(body, "Branch")
    created = frontmatter.get("created") or _find_field(body, "Created")
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
    rel = plan.path.relative_to(repo_root) if plan.path.is_absolute() else plan.path
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
_FENCE_RE = re.compile(r"^```(\w*)\s*$")


def _inline_md(text: str) -> str:
    text = html.escape(text, quote=False)
    text = _INLINE_CODE_RE.sub(lambda m: f"<code>{m.group(1)}</code>", text)
    text = _BOLD_RE.sub(lambda m: f"<strong>{m.group(1)}</strong>", text)
    text = _ITALIC_RE.sub(lambda m: f"<em>{m.group(1)}</em>", text)
    text = _LINK_RE.sub(
        lambda m: f'<a href="{html.escape(m.group(2), quote=True)}">{m.group(1)}</a>',
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
        f'<div class="meta-row">{chip}{bug_chip}{progress}<span>{_esc(plan.last_touched or plan.created or "—")}{prs}</span></div>'
        f"{edges_html}"
        f"{fixed_by_html}"
        f"</div>"
    )


def render_dashboard(
    plans: dict[str, Plan],
    plans_dir: Path,
    out_dir: Path,
    git_head_sha: str,
    template: str,
    readme_used: bool,
) -> str:
    # Group by component
    by_component: dict[str, list[Plan]] = {}
    for p in plans.values():
        by_component.setdefault(p.component, []).append(p)
    # Sort each component by last-touched desc
    for plans_in in by_component.values():
        plans_in.sort(key=lambda x: x.last_touched or x.created or "", reverse=True)

    component_sections: list[str] = []
    for comp in COMPONENT_ORDER:
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
    corpus_sha = hashlib.sha256(
        "".join(sorted(p.render_sha or p.sha256 for p in plans.values())).encode(
            "utf-8"
        )
    ).hexdigest()
    plans_dir_short = str(plans_dir).replace(str(Path.home()), "~")
    readme_note = (
        " · status grouping from <code>README.md</code>"
        if readme_used
        else " · status from per-plan <code>**Status:**</code> headers"
    )

    html_out = template
    substitutions = {
        "{{CORPUS_SHA}}": corpus_sha,
        "{{PLANS_DIR}}": str(plans_dir),
        "{{PLANS_DIR_SHORT}}": plans_dir_short,
        "{{GIT_HEAD}}": git_head_sha,
        "{{GIT_HEAD_SHORT}}": git_head_sha[:7] if git_head_sha else "—",
        "{{GENERATED_AT}}": now_iso,
        "{{GENERATED_AT_SHORT}}": now_short,
        "{{PLAN_COUNT}}": str(len(plans)),
        "{{SUMMARY_CHIPS}}": summary_chips,
        "{{COMPONENTS}}": "\n".join(component_sections),
        "{{README_NOTE}}": readme_note,
    }
    for key, val in substitutions.items():
        html_out = html_out.replace(key, val)
    return html_out


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
    plan: Plan, plans: dict[str, Plan], git_head_sha: str, template: str
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
            f'<span class="sha">{c.short_sha}</span>'
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
        "{{GIT_HEAD}}": git_head_sha,
        "{{GENERATED_AT}}": now_iso,
        "{{GENERATED_AT_SHORT}}": now_short,
        "{{TITLE}}": _esc(plan.title),
        "{{COMPONENT}}": plan.component,
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
    out = template
    for key, val in substitutions.items():
        out = out.replace(key, val)
    return out


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
        if existing_sha_m and existing_sha_m.group(1) == source_sha:
            existing_stable = _stable_content(existing)
            new_stable = _stable_content(new_content)
            if existing_stable == new_stable:
                return (True, f"unchanged {path.name}")
            return (
                False,
                f"refused: {path.name} differs from regen but source markdown unchanged "
                f"(hand-edit suspected); pass --force to overwrite",
            )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new_content, encoding="utf-8")
    return True, f"wrote {path.name}"


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

    # Dashboard
    dashboard_html = render_dashboard(
        plans,
        plans_dir,
        out_dir,
        git_head_sha,
        dashboard_template,
        readme_used,
    )
    corpus_sha = hashlib.sha256(
        "".join(sorted(p.render_sha for p in plans.values())).encode("utf-8")
    ).hexdigest()
    wrote, msg = write_with_drift_guard(
        out_dir / "index.html",
        dashboard_html,
        corpus_sha,
        args.force,
    )
    print(msg)

    refused = 0
    written = 1 if wrote else 0
    for plan in plans.values():
        page_html = render_plan_page(plan, plans, git_head_sha, plan_template)
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
    return 0 if refused == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
