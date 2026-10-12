#!/usr/bin/env python3
"""render-report.py - render one self-contained HTML review report.

Opt-in renderer behind the `--report` flag of review-gauntlet and deep-review.
It only reads the files it is handed and writes one HTML file. It never calls
git or gh, never mutates a ledger or any state file, and uses the Python
standard library only.

Usage:
  render-report.py [--ledger <path>] [--round N=<envelope>]...
                   [--envelope <path>] [--suppress-keys <file>]
                   [--diff-stat <file>] --root <dir> --out <file>

Inputs:
  --ledger        review-gauntlet ledger JSON ({loop_counter, rounds}). It has
                  no schema_version and is never version-checked.
  --round N=PATH  the reconciled envelope of gauntlet round N (repeatable). A
                  PATH that does not exist renders as "round N: envelope
                  missing". Flag order is irrelevant; a duplicate N is a usage
                  error. The severity section renders the highest round
                  (the larger of the ledger's round count and the highest N)
                  only. When that round's envelope is missing the section says
                  "round N: envelope missing \u2014 findings unavailable" rather than
                  showing an older round's findings as current; earlier rounds
                  feed the convergence rows.
  --envelope      one reconciler v2 envelope (deep-review). Mutually exclusive
                  with --round.
  --suppress-keys one key per line, `file<TAB>line<TAB>category` for an
                  anchored finding (non-empty file and line), or
                  `file<TAB>line<TAB>category<TAB>summary` for an unanchored
                  one (empty file and/or empty line; empty line for null, absent
                  or -1). `summary` is the finding's `summary` (else `finding`)
                  with each tab, CR and LF replaced by one space. An anchored
                  finding is dropped by a matching 3-field key, or a matching
                  4-field key whose summary also matches; an unanchored finding
                  only by a 4-field key matching all four fields, so one key
                  never drops every unanchored finding of a category. A
                  missing file means no filtering.
  --diff-stat     file written by report-hook.sh: an optional header line
                  `# diff-stat mode=<range|failed> ...` followed by
                  `git diff --stat` text. An absent flag renders "diff scope
                  unavailable". A given-but-unreadable path is a failure.
  --root, --out   output containment: --out must sit inside --root, with no
                  `..` and no symlink component below --root.

Environment (tests only): SKEIN_REPORT_NOW fixes the "generated" timestamp,
and is honoured only when SKEIN_REPORT_TEST=1 is also set.

Exit codes:
  0  report written
  1  failure (missing or unreadable input, malformed JSON, schema_version
     mismatch on an envelope, empty envelope file, containment refusal, write
     error). A clear message goes to stderr; no output file or temp residue.
  2  usage error (--envelope with --round, --round without --ledger, no input,
     duplicate or malformed --round N, unknown flag).

Envelopes are the audited reconciler v2 output (schema_version == 2). The
renderer never re-implements dedup. All finding text is untrusted: every value
is escaped for text nodes and attributes, the page has inline CSS only, and it
carries no script and no external URL.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from datetime import datetime, timezone

PROG = "render-report"
SEVERITIES = ("Critical", "Important", "Minor")
OTHER = "Other"
# Case-insensitive severity aliases; anything else lands in Other.
SEVERITY_ALIASES = {
    "critical": "Critical",
    "high": "Critical",
    "important": "Important",
    "medium": "Important",
    "minor": "Minor",
    "low": "Minor",
}
EXPECTED_SCHEMA = 2
SUPPRESSED_LABEL = "as reviewed; suppressed and auto-fixed findings omitted"


class Failure(Exception):
    """A renderer failure: message to stderr, exit 1."""


class Usage(Exception):
    """A usage error: message to stderr, exit 2."""


def esc(value: object) -> str:
    """Escape any value for both text nodes and attribute values."""
    return html.escape(str(value), quote=True)


# ---------------------------------------------------------------- input


def read_json_file(path: str, what: str) -> object:
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except FileNotFoundError:
        raise Failure(f"{what} not found: {path}") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise Failure(f"{what} unreadable: {path} ({exc})") from None
    if not raw.strip():
        raise Failure(f"{what} is empty: {path}")
    try:
        return json.loads(raw)
    except (ValueError, RecursionError) as exc:
        raise Failure(f"{what} is not valid JSON: {path} ({exc})") from None


def load_envelope(path: str) -> dict:
    data = read_json_file(path, "envelope")
    if not isinstance(data, dict):
        raise Failure(f"envelope is not a JSON object: {path}")
    version = data.get("schema_version")
    if version != EXPECTED_SCHEMA or isinstance(version, bool):
        raise Failure(
            f"envelope schema_version must be {EXPECTED_SCHEMA} "
            f"(got {version!r}): {path}"
        )
    if not isinstance(data.get("findings"), list):
        raise Failure(f"envelope has no findings array: {path}")
    return data


def load_ledger(path: str) -> dict:
    data = read_json_file(path, "ledger")
    if not isinstance(data, dict) or not isinstance(data.get("rounds"), list):
        raise Failure(f"ledger is not a gauntlet ledger (no rounds array): {path}")
    return data


def parse_round_flags(values: list[str]) -> dict[int, str]:
    rounds: dict[int, str] = {}
    for value in values:
        number, sep, path = value.partition("=")
        if not sep or not re.fullmatch(r"[0-9]+", number) or not path:
            raise Usage(
                f"--round expects N=<envelope> with N a positive integer: {value}"
            )
        n = int(number)
        if n < 1:
            raise Usage(f"--round N must be >= 1: {value}")
        if n in rounds:
            raise Usage(f"duplicate --round {n}")
        rounds[n] = path
    return rounds


def norm_line(value: object) -> str:
    """Line as it appears in a suppress key: '' for null or the -1 sentinel."""
    if value is None or isinstance(value, bool):
        return ""
    try:
        number = int(value)  # type: ignore[call-overload]
    except (TypeError, ValueError, OverflowError):
        # OverflowError: JSON `1e999` parses to inf, which int() rejects.
        return str(value)
    return "" if number == -1 else str(number)


def norm_summary(value: object) -> str:
    """Summary as it appears in a suppress key: tab/CR/LF each become a space."""
    return re.sub(r"[\t\r\n]", " ", str(value or ""))


def finding_summary(finding: dict) -> str:
    return norm_summary(finding.get("summary") or finding.get("finding") or "")


def finding_tuple(finding: dict) -> tuple[str, str, str]:
    return (
        str(finding.get("file") or ""),
        norm_line(finding.get("line")),
        str(finding.get("category") or ""),
    )


def is_suppressed(finding: dict, suppress: set[tuple[str, ...]]) -> bool:
    """True when a suppress key drops this finding (see --suppress-keys)."""
    base = finding_tuple(finding)
    if (*base, finding_summary(finding)) in suppress:
        return True
    anchored = bool(base[0]) and bool(base[1])
    return anchored and base in suppress


def load_suppress_keys(path: str | None) -> set[tuple[str, ...]]:
    if not path or not os.path.exists(path):
        return set()
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            raw = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise Failure(f"suppress-keys unreadable: {path} ({exc})") from None
    # Split on LF (and CRLF) only, never str.splitlines(): that also breaks on
    # \x0b, \x0c, \x1c-\x1e, \x85, U+2028 and U+2029, which norm_summary leaves
    # inside a summary, so such a key would be cut in two and never match.
    lines = raw.replace("\r\n", "\n").split("\n")
    keys: set[tuple[str, ...]] = set()
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("\t", 3)
        if len(parts) < 3:
            continue
        parts[1] = "" if parts[1] == "-1" else parts[1]
        keys.add(tuple(parts))
    return keys


def load_diff_stat(path: str | None) -> dict:
    """Return {'state': absent|failed|ok, 'header': str, 'text': str}."""
    if path is None:
        return {"state": "absent", "header": "", "text": ""}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        raise Failure(f"diff-stat unreadable: {path} ({exc})") from None
    header = ""
    text = raw
    if raw.startswith("# diff-stat"):
        header, _, text = raw.partition("\n")
        header = header[2:]
    state = "failed" if re.search(r"\bmode=failed\b", header) else "ok"
    return {"state": state, "header": header, "text": text.rstrip("\n")}


# ---------------------------------------------------------------- render

CSS = """
:root{color-scheme:light dark;--bg:#fff;--fg:#1c1f24;--muted:#5b6370;
--line:#d8dce3;--card:#f6f7f9;--crit:#b3261e;--imp:#a15c00;--min:#1f6f43;
--oth:#5b6370}
@media (prefers-color-scheme:dark){:root{--bg:#14161a;--fg:#e6e8ec;
--muted:#9aa3b0;--line:#2c313a;--card:#1c2026;--crit:#ff8a80;--imp:#ffb74d;
--min:#7bd8a4;--oth:#9aa3b0}}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);
font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:960px;margin:0 auto}
h1{font-size:1.5rem;margin:0 0 4px}
h2{font-size:1.15rem;margin:28px 0 8px;border-bottom:1px solid var(--line);
padding-bottom:4px}
.meta,.note{color:var(--muted);font-size:.9rem}
.sev-Critical h2 span{color:var(--crit)}.sev-Important h2 span{color:var(--imp)}
.sev-Minor h2 span{color:var(--min)}.sev-Other h2 span{color:var(--oth)}
article{background:var(--card);border:1px solid var(--line);border-radius:6px;
padding:10px 12px;margin:8px 0;overflow-wrap:anywhere}
article h3{font-size:1rem;margin:0 0 4px}
dl{margin:6px 0 0}dt{font-weight:600;font-size:.85rem;color:var(--muted)}
dd{margin:0 0 6px;white-space:pre-wrap}
code,pre{font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}
pre{background:var(--card);border:1px solid var(--line);border-radius:6px;
padding:10px;overflow-x:auto;white-space:pre}
.tablewrap{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{border:1px solid var(--line);padding:4px 8px;text-align:left}
th{background:var(--card)}
"""


def fmt_location(finding: dict) -> str:
    file_part = str(finding.get("file") or "")
    line = norm_line(finding.get("line"))
    if file_part and line:
        return f"{file_part}:{line}"
    return file_part or "(no location)"


def render_finding(finding: dict) -> str:
    summary = str(finding.get("summary") or finding.get("finding") or "(no summary)")
    marker = (
        ' <span class="auto-fixable">[AUTO-FIXABLE]</span>'
        if finding.get("auto_fix_status") == "would_apply"
        else ""
    )
    lenses = finding.get("lenses")
    if isinstance(lenses, list) and lenses:
        lens_text = ", ".join(str(x) for x in lenses)
    else:
        lens_text = str(finding.get("lens") or "")
    rows = [("Location", fmt_location(finding))]
    category = str(finding.get("category") or "")
    if category:
        rows.append(("Category", category))
    if lens_text:
        rows.append(("Lenses", lens_text))
    confidence = finding.get("confidence")
    if confidence is not None and not isinstance(confidence, bool):
        rows.append(("Confidence", str(confidence)))
    evidence = str(finding.get("evidence") or "")
    if evidence:
        rows.append(("Evidence", evidence))
    suggestion = str(finding.get("suggestion") or "")
    if suggestion:
        rows.append(("Suggestion", suggestion))
    body = "".join(f"<dt>{esc(k)}</dt><dd>{esc(v)}</dd>" for k, v in rows)
    return f"<article><h3>{esc(summary)}{marker}</h3><dl>{body}</dl></article>"


def render_related(related: object) -> str:
    if not isinstance(related, list) or not related:
        return ""
    rows = []
    for item in related:
        if not isinstance(item, dict):
            continue
        location = fmt_location(item)
        categories = item.get("categories")
        if isinstance(categories, list):
            category_text = ", ".join(str(value) for value in categories)
        else:
            category_text = ""
        rows.append(f"<tr><td>{esc(location)}</td><td>{esc(category_text)}</td></tr>")
    if not rows:
        return ""
    return (
        '<section class="related"><h3>Related findings</h3>'
        '<div class="tablewrap"><table><tr><th>Location</th>'
        f"<th>Categories</th></tr>{''.join(rows)}</table></div></section>"
    )


def bucket_findings(findings: list) -> dict[str, list[dict]]:
    buckets: dict[str, list[dict]] = {s: [] for s in (*SEVERITIES, OTHER)}
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        severity = finding.get("severity")
        key = OTHER
        if isinstance(severity, str):
            key = SEVERITY_ALIASES.get(severity.strip().lower(), OTHER)
        buckets[key].append(finding)
    return buckets


def render_severity(
    envelope: dict, suppress: set[tuple[str, ...]], label_suppressed: bool
) -> tuple[str, int]:
    findings = [f for f in envelope["findings"] if isinstance(f, dict)]
    kept = [f for f in findings if not is_suppressed(f, suppress)]
    omitted = len(findings) - len(kept)
    buckets = bucket_findings(kept)
    parts = []
    summary = envelope.get("summary")
    if isinstance(summary, dict):
        stats = " ".join(
            f"{esc(k)}={esc(summary[k])}"
            for k in ("raw", "merged", "unique", "related", "dropped")
            if k in summary
        )
        if stats:
            parts.append(f'<p class="meta">Reconciliation: {stats}</p>')
    parts.append(render_related(envelope.get("related")))
    if label_suppressed:
        parts.append(f'<p class="note">{esc(SUPPRESSED_LABEL)}</p>')
        if omitted:
            parts.append(f'<p class="note">{omitted} finding(s) omitted.</p>')
    for name in (*SEVERITIES, OTHER):
        items = buckets[name]
        if name == OTHER and not items:
            continue
        inner = (
            "".join(render_finding(f) for f in items)
            if items
            else '<p class="note">None.</p>'
        )
        parts.append(
            f'<section class="sev-{name}" id="sev-{name.lower()}">'
            f"<h2><span>{name}</span> ({len(items)})</h2>{inner}</section>"
        )
    return "".join(parts), len(kept)


def cell(value: object) -> str:
    return "-" if value is None else esc(value)


def render_convergence(
    ledger: dict, round_paths: dict[int, str], present: set[int]
) -> str:
    rounds = ledger["rounds"]
    count = max([len(rounds), *round_paths])
    parts = []
    meta = []
    for key in ("target", "loop_counter", "cap", "k"):
        if ledger.get(key) is not None:
            meta.append(f"{esc(key)}={esc(ledger[key])}")
    if meta:
        parts.append(f'<p class="meta">{" ".join(meta)}</p>')
    if not round_paths:
        parts.append(
            '<p class="note">Counts only: no round envelopes were supplied, '
            "so findings are not shown.</p>"
        )
    head = (
        "<tr><th>Round</th><th>Pass</th><th>Findings</th><th>Structural</th>"
        "<th>Local</th><th>Quarantine</th><th>Unresolved gates</th>"
        "<th>Envelope</th></tr>"
    )
    body = []
    for n in range(1, count + 1):
        row = (
            rounds[n - 1]
            if n <= len(rounds) and isinstance(rounds[n - 1], dict)
            else {}
        )
        if not round_paths:
            envelope_note = "counts only"
        elif n in present:
            envelope_note = "present"
        else:
            envelope_note = f"round {n}: envelope missing"
        body.append(
            f"<tr><td>{n}</td><td>{cell(row.get('pass_type'))}</td>"
            f"<td>{cell(row.get('count'))}</td>"
            f"<td>{cell(row.get('structural_tally'))}</td>"
            f"<td>{cell(row.get('local_tally'))}</td>"
            f"<td>{cell(row.get('quarantine_size'))}</td>"
            f"<td>{cell(row.get('unresolved_gates'))}</td>"
            f"<td>{esc(envelope_note)}</td></tr>"
        )
    if count == 0:
        parts.append('<p class="note">The ledger records no rounds.</p>')
    else:
        parts.append(
            f'<div class="tablewrap"><table>{head}{"".join(body)}</table></div>'
        )
    return "".join(parts)


def render_diff_scope(diff: dict) -> str:
    if diff["state"] == "absent":
        return '<p class="note">diff scope unavailable</p>'
    if diff["state"] == "failed":
        header = f'<p class="meta">{esc(diff["header"])}</p>' if diff["header"] else ""
        return f'{header}<p class="note">diff scope unavailable (git diff failed)</p>'
    header = f'<p class="meta">{esc(diff["header"])}</p>' if diff["header"] else ""
    text = diff["text"] or "(empty diff)"
    return f"{header}<pre>{esc(text)}</pre>"


def render_page(
    kind: str,
    generated: str,
    severity_html: str,
    convergence_html: str | None,
    diff_html: str,
    total: int | None,
) -> str:
    sections = []
    if convergence_html is not None:
        sections.append(f"<section><h2>Convergence</h2>{convergence_html}</section>")
    if severity_html:
        heading = "Findings" if total is None else f"Findings ({total})"
        sections.append(f"<section><h2>{esc(heading)}</h2>{severity_html}</section>")
    sections.append(f"<section><h2>Diff scope</h2>{diff_html}</section>")
    return (
        "<!DOCTYPE html>\n"
        '<html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<title>Review report - {esc(kind)}</title>"
        f"<style>{CSS}</style></head><body><main>"
        f"<h1>Review report</h1>"
        f'<p class="meta">{esc(kind)} - generated {esc(generated)}</p>'
        f"{''.join(sections)}"
        "</main></body></html>\n"
    )


# ---------------------------------------------------------------- output


def check_containment(root: str, out: str) -> str:
    """Return the absolute out path, or raise Failure on any refusal."""
    for label, value in (("--root", root), ("--out", out)):
        if not value:
            raise Failure(f"{label} is empty")
        if ".." in value.replace("\\", "/").split("/"):
            raise Failure(f"{label} contains '..': {value}")
    root_abs = os.path.abspath(root)
    out_abs = os.path.abspath(out)
    if out_abs == root_abs or os.path.commonpath([root_abs, out_abs]) != root_abs:
        raise Failure(f"--out is outside --root: {out}")
    rel = os.path.relpath(out_abs, root_abs)
    current = root_abs
    for part in rel.split(os.sep):
        current = os.path.join(current, part)
        if os.path.islink(current):
            raise Failure(f"refusing to write through a symlink: {current}")
    parent = os.path.dirname(out_abs)
    if not os.path.isdir(parent):
        raise Failure(f"output directory does not exist: {parent}")
    if os.path.exists(out_abs) and not os.path.isfile(out_abs):
        raise Failure(f"--out exists and is not a regular file: {out}")
    return out_abs


def write_contained(out_abs: str, content: str) -> None:
    tmp = f"{out_abs}.tmp.{os.getpid()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    created = False
    try:
        fd = os.open(tmp, flags, 0o644)
        created = True
        # errors="replace": finding text is untrusted JSON, and a lone surrogate
        # escape (`"\ud800"`) survives html.escape but cannot be encoded as UTF-8.
        with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as fh:
            fh.write(content)
        os.replace(tmp, out_abs)
    except OSError as exc:
        raise Failure(f"cannot write report: {out_abs} ({exc})") from None
    finally:
        if created:
            try:
                os.unlink(tmp)
            except OSError:
                pass


# ---------------------------------------------------------------- main


class ArgParser(argparse.ArgumentParser):
    def error(self, message: str):  # type: ignore[override]
        raise Usage(message)


def build_parser() -> ArgParser:
    p = ArgParser(prog=PROG, add_help=True)
    p.add_argument("--ledger")
    p.add_argument("--round", action="append", default=[], dest="rounds")
    p.add_argument("--envelope")
    p.add_argument("--suppress-keys", dest="suppress_keys")
    p.add_argument("--diff-stat", dest="diff_stat")
    p.add_argument("--root", required=True)
    p.add_argument("--out", required=True)
    return p


def run(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    if args.envelope and args.rounds:
        raise Usage("--envelope cannot be combined with --round")
    if args.rounds and not args.ledger:
        raise Usage("--round requires --ledger")
    if not args.envelope and not args.ledger:
        raise Usage("no input: pass --ledger (gauntlet) or --envelope (deep-review)")
    round_paths = parse_round_flags(args.rounds)

    # Containment first: a refused path never reads or writes anything.
    out_abs = check_containment(args.root, args.out)

    # timezone.utc, not datetime.UTC: stock macOS python3 is 3.9
    now_utc = datetime.now(timezone.utc)  # noqa: UP017
    fixed_now = ""
    if os.environ.get("SKEIN_REPORT_TEST") == "1":
        fixed_now = os.environ.get("SKEIN_REPORT_NOW", "")
    generated = fixed_now or now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    diff = load_diff_stat(args.diff_stat)
    suppress = load_suppress_keys(args.suppress_keys)

    if args.envelope:
        envelope = load_envelope(args.envelope)
        severity_html, total = render_severity(envelope, suppress, True)
        page = render_page(
            "deep-review",
            generated,
            severity_html,
            None,
            render_diff_scope(diff),
            total,
        )
    else:
        ledger = load_ledger(args.ledger)
        present: set[int] = set()
        envelopes: dict[int, dict] = {}
        for n, path in round_paths.items():
            if os.path.exists(path):
                envelopes[n] = load_envelope(path)
                present.add(n)
        convergence_html = render_convergence(ledger, round_paths, present)
        severity_html, total = "", None
        if round_paths:
            # The highest round the run reached, by the ledger or by a flag.
            top = max([len(ledger["rounds"]), *round_paths])
            if top in envelopes:
                severity_html, total = render_severity(envelopes[top], suppress, False)
                severity_html = (
                    f'<p class="note">Round {top} (latest round).</p>' + severity_html
                )
            else:
                # Never fall back to an older round: its findings are not current.
                severity_html = (
                    f'<p class="note">round {top}: envelope missing \u2014 '
                    "findings unavailable</p>"
                )
        page = render_page(
            "review-gauntlet",
            generated,
            severity_html,
            convergence_html,
            render_diff_scope(diff),
            total,
        )
    write_contained(out_abs, page)
    return 0


def main(argv: list[str]) -> int:
    try:
        return run(argv)
    except Usage as exc:
        print(f"{PROG}: usage: {exc}", file=sys.stderr)
        return 2
    except Failure as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1
    except SystemExit as exc:  # --help
        code = exc.code
        return code if isinstance(code, int) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
