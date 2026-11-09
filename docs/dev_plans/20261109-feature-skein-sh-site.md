# Task: skein.sh static site

**Status**: In Progress
**Component**: site
**Assigned to**: Claude
**Priority**: Medium
**Branch**: feature/skein-sh-site
**Created**: 2026-11-09
**Review Gates:** none

## Objective

Host a small static site at skein.sh on Cloudflare Workers: a home page that shows how the skills connect and why that makes code sturdier, plus an install page.

## Requirements

- Home page: hero with the Claude Code install commands, an interactive skill map (five lanes: Plan, Stress-test, Build, Verify, Ship) with hand-off edges, a short "why it's sturdier" section, and a strip of standalone skills.
- Install page: Claude Code, Codex CLI and Pi commands, pinning, updating, and a first plan-to-ship run.
- No page per skill; the map's detail panel carries per-skill information.
- No framework, no build step, no external requests. Light and dark, readable at phone width.
- Hosted as an assets-only Worker (`wrangler.jsonc`, `site/`), custom domain skein.sh.

## Technical Specifications

- `site/graph.json` is the single curated source for lanes, nodes, edges and the standalone-skill strip. Descriptions are hand-written because the SKILL.md frontmatter is too long to display.
- `site/graph.js` renders HTML cards and measures them to draw SVG edges. Below 900px the lanes stack and edges are hidden; the panel still lists what each skill takes and hands on.
- `site/_headers` sets a strict CSP (`script-src 'self'; style-src 'self'`), so pages carry no inline script, style or event handlers.
- Install commands are copied from README.md; a test fails if they drift.
- Colour tokens are declared once with `light-dark()`; the toggle sets `color-scheme` via `data-theme`.
- `workers_dev` and `preview_urls` are off, so the site is only reachable on skein.sh and www.skein.sh.

## Implementation Checklist

- [x] Site pages, styles, scripts, `graph.json`, favicon, 404, `_headers`
- [x] `wrangler.jsonc`
- [x] `tests/site/test_site.py`, wired into `just ci` as `site-tests`
- [x] `just site-build`, `site-preview`, `site-deploy`
- [x] AGENTS.md recipe registry, README layout, CHANGELOG
- [ ] Add `skein.sh` zone to Cloudflare and run the first `just site-deploy`

## Testing Notes

- `just site-tests`: every skill appears on the site exactly once; edges, lanes and parents resolve; install commands appear in the README; pages are CSP-clean and internal links resolve.
- `just site-build` dry-runs the deploy bundle.
- Checked by hand with `just site-preview` at 1280px and 390px.

## Open Questions

- Whether a per-skill page is wanted later, once we see what the panel is missing.
- `www.skein.sh` is served as a second custom domain; pages carry a canonical link to the apex.
