# Widget toolkit

Reusable templates for plan-view rich HTML pages. Load `base.css` once on the
host page; each widget is a self-contained HTML fragment with `{{PLACEHOLDER}}`
substitution points that a renderer fills in. The HTML comment at the top of
each file is the source of truth for the input shape.

Use widgets when the data is *structurally* shaped (a state graph, a timeline,
a route table). Fall back to rendered markdown when content is narrative prose,
short bullet lists, or one-off layouts — widgets are not a goal in themselves.

## Widgets

- **`base.css`** — shared colour variables (dark + light via
  `prefers-color-scheme`), typography, `.card`, `.chip`, `.section`,
  `.banner`, `.tabs` scaffold, `.progress-bar`, `footer.page-footer`. Load
  once. Do not duplicate selectors here in widget files.

- **`tabs.html`** — pure-CSS tabbed container using `<input type="radio">` +
  `:checked` sibling selectors (no JS). Input: `{ id, tabs: [{ slot, label,
  count?, checked?, content_html }] }`. Use when a single page has 3+ distinct
  views of the same artefact (Overview / Architecture / Phases / Findings).
  Fall back to a single scrolling page when there are only one or two
  sections.

- **`state-machine.svg.html`** — generic FSM diagram. Input: `{ states:
  [{id,label,x,y,kind,sublabel}], transitions: [{from,to,label,style,curve,
  kind}], legend, viewBox }`. `kind` controls colour (start/normal/terminal/
  error); `curve` is `auto|above|below`. Use for any small finite-state graph
  (≤ 8 states). For larger graphs, embed a Mermaid block instead.

- **`compare.svg.html`** — today-vs-proposed side-by-side. Input: `{ left,
  right, mapping? }` where each side has `{title, kind, header_box,
  subsystem_label, items: [{text, kind}], caption}`. Use when the audience
  needs to see a *delta*; for a single architecture, use `state-machine.svg`
  or a Mermaid diagram instead.

- **`timeline.html`** — vertical event timeline with coloured dots. Input:
  `{ title?, events: [{date,label,kind,short_sha?,href?,plan_link?}] }`.
  `kind` ∈ `commit|finding|fixed|phase|review|live|race|harness|neutral`.
  Use for project history or findings/conduct timelines. Fall back to a
  markdown ordered list when there are fewer than four events.

- **`table.html`** — searchable table with optional chip filter. Input:
  `{ id, search, filter?: {column, mode: exact|prefix, values}, columns, rows
  }`. JS is inline and scoped by `id` so multiple tables coexist. Use for
  ≥ 10 rows where the reader will want to grep or filter (routes, env vars,
  prompt catalogue). Fall back to a static markdown table otherwise.
