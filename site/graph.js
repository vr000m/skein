// Renders the skill map from /graph.json: HTML cards in lane columns, with an
// SVG layer of hand-off edges measured from the laid-out cards. Below 900px
// the lanes stack and the edge layer is hidden; the detail panel still lists
// what each skill takes from and hands to.
(async () => {
  const SVG_NS = "http://www.w3.org/2000/svg";
  const root = document.getElementById("map");
  if (!root) return;

  let data;
  try {
    data = await (await fetch("/graph.json")).json();
  } catch {
    root.textContent = "The skill map failed to load. The skills are listed on GitHub.";
    return;
  }

  const nodes = new Map(data.nodes.map((n) => [n.id, n]));
  const bands = data.bands || [];
  const lanesById = new Map([...data.lanes, ...bands].map((l) => [l.id, l]));
  const laneIndex = new Map(data.lanes.map((l, i) => [l.id, i]));
  const children = new Map();
  for (const n of data.nodes) {
    if (n.parent) children.set(n.parent, [...(children.get(n.parent) || []), n]);
  }

  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  };
  const richEl = (tag, cls, text) => {
    const e = el(tag, cls);
    let offset = 0;
    for (const match of text.matchAll(/`([^`]+)`/g)) {
      e.append(text.slice(offset, match.index), el("code", null, match[1]));
      offset = match.index + match[0].length;
    }
    e.append(text.slice(offset));
    return e;
  };
  const svgEl = (tag, attrs = {}) => {
    const e = document.createElementNS(SVG_NS, tag);
    for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
    return e;
  };
  const KIND = {
    skill: (n) => `skein skill · ${lanesById.get(n.lane).label}`,
    builtin: () => "Claude Code built-in · not part of skein",
    manual: () => "Claude Code built-in · you run it",
  };

  // ---- build DOM ---------------------------------------------------------
  const svg = svgEl("svg", { id: "edges", "aria-hidden": "true" });
  const defs = svgEl("defs");
  const marker = svgEl("marker", {
    id: "arrow", markerWidth: 8, markerHeight: 8, refX: 7, refY: 4, orient: "auto",
  });
  marker.append(svgEl("path", { d: "M0,0 L8,4 L0,8 z" }));
  defs.append(marker);
  svg.append(defs);

  const lanesEl = el("div", "lanes");
  const card = new Map(); // id -> outer element used for edge geometry
  const chips = new Map(); // child id -> chip button

  const makeNodeBtn = (n) => {
    const btn = el("button", "node");
    btn.type = "button";
    btn.append(el("span", "name", n.id), richEl("span", "sum", n.summary));
    btn.addEventListener("click", () => select(n.id, true));
    return btn;
  };

  for (const lane of data.lanes) {
    const laneEl = el("section", "lane");
    laneEl.dataset.lane = lane.id;
    laneEl.append(el("h3", null, lane.label), el("p", "blurb", lane.blurb));
    const list = el("div", "lane-nodes");
    for (const n of data.nodes.filter((x) => x.lane === lane.id && !x.parent)) {
      const btn = makeNodeBtn(n);
      const kids = children.get(n.id);
      if (kids) {
        const group = el("div", "card-group");
        const loops = el("div", "loops");
        loops.append(el("small", null, "Review gates"));
        for (const k of kids) {
          const chip = el("button", `chip ${k.kind}`, k.id);
          chip.type = "button";
          if (k.kind !== "skill") chip.append(el("span", "tag", k.kind === "manual" ? "run first" : "built-in"));
          chip.addEventListener("click", () => select(k.id, true));
          chips.set(k.id, chip);
          loops.append(chip);
        }
        group.append(btn, loops);
        list.append(group);
        card.set(n.id, group);
      } else {
        list.append(btn);
        card.set(n.id, btn);
      }
    }
    laneEl.append(list);
    lanesEl.append(laneEl);
  }

  // Cross-cutting skills sit in a full-width band under the lanes; they have
  // no hand-off edges, only `uses` links to the stages they help.
  const bandsEl = el("div", "bands");
  for (const band of bands) {
    const bandEl = el("section", "band");
    bandEl.append(el("h3", null, band.label), el("p", "blurb", band.blurb));
    for (const n of data.nodes.filter((x) => x.lane === band.id)) {
      const btn = makeNodeBtn(n);
      bandEl.append(btn);
      card.set(n.id, btn);
    }
    bandsEl.append(bandEl);
  }
  root.append(svg, lanesEl, bandsEl);

  const panel = el("div", "panel");
  panel.setAttribute("aria-live", "polite");
  root.after(panel);

  // ---- panel -------------------------------------------------------------
  const topOf = (n) => n.parent || n.id;
  // Every relationship that should light up related cards: real hand-off
  // edges plus a cross-cutting skill's `uses` links.
  const links = [
    ...data.edges.map((e) => [e.from, e.to]),
    ...data.nodes.flatMap((n) => (n.uses || []).map((u) => [n.id, u.id])),
  ];

  const linkItem = (id, label) => {
    const li = el("li");
    const b = el("button", null, id);
    b.type = "button";
    b.addEventListener("click", () => {
      select(id, true);
      // The clicked button was destroyed with the old panel; keep keyboard
      // focus inside the panel instead of dropping it to <body>.
      panel.querySelector("h3").focus({ preventScroll: true });
    });
    li.append(b);
    if (label) li.append(richEl("span", null, ` — ${label}`));
    return li;
  };
  const listBlock = (title, items, cls) => {
    const d = el("div", cls);
    d.append(el("h4", null, title));
    if (!items.length) {
      d.append(el("p", "none", "—"));
      return d;
    }
    const ul = el("ul");
    ul.append(...items);
    d.append(ul);
    return d;
  };

  function renderPanel(n) {
    panel.style.setProperty("--lane-colour", laneIndex.has(n.lane) ? `var(--l-${n.lane})` : "var(--accent)");
    const top = topOf(n);
    const cmd = el("div", "cmd");
    const code = el("code", null, n.cmd);
    const copy = el("button", "copy", "Copy");
    copy.type = "button";
    cmd.append(code, copy);

    const cols = el("div", "cols");
    if (n.parent) {
      const sibs = (children.get(n.parent) || []).filter((k) => k.id !== n.id);
      cols.append(
        listBlock(n.kind === "manual" ? "Run before" : "Runs inside", [linkItem(n.parent)]),
        listBlock("Other gates", sibs.map((k) => linkItem(k.id))),
      );
    } else if (n.uses) {
      cols.append(listBlock("Use it to", n.uses.map((u) => linkItem(u.id, u.note)), "span2"));
    } else {
      cols.append(
        listBlock("Takes", data.edges.filter((e) => e.to === top).map((e) => linkItem(e.from, e.label))),
        listBlock("Hands off to", data.edges.filter((e) => e.from === top).map((e) => linkItem(e.to, e.label))),
      );
      const kids = children.get(top);
      if (kids) cols.append(listBlock("Review gates", kids.map((k) => linkItem(k.id, k.summary)), "span2"));
      const helpers = data.nodes.filter((h) => (h.uses || []).some((u) => u.id === top));
      if (helpers.length) {
        cols.append(
          listBlock("Helped by", helpers.map((h) => linkItem(h.id, h.uses.find((u) => u.id === top).note)), "span2"),
        );
      }
    }
    const heading = el("h3", null, n.id);
    heading.tabIndex = -1; // focus target after a panel link is activated
    panel.replaceChildren(
      el("span", "badge", KIND[n.kind](n)),
      heading,
      richEl("p", null, n.detail),
      cmd,
      cols,
    );
  }

  // ---- selection ---------------------------------------------------------
  let selectedId = null;
  const pathEls = [];

  function select(id, userInitiated) {
    const n = nodes.get(id);
    if (!n) return;
    selectedId = id;
    const top = topOf(n);
    const related = new Set([top]);
    for (const [from, to] of links) {
      if (from === top) related.add(to);
      if (to === top) related.add(from);
    }
    for (const [cid, c] of card) {
      c.classList.toggle("is-selected", cid === top);
      c.classList.toggle("is-related", related.has(cid) && cid !== top);
      c.classList.toggle("is-dim", !related.has(cid));
    }
    for (const [kid, c] of chips) c.classList.toggle("is-selected", kid === id);
    markPaths(top);
    renderPanel(n);
    // No explicit `behavior`: the page's CSS `scroll-behavior` decides, so
    // prefers-reduced-motion is honoured.
    if (userInitiated && !wide.matches) {
      panel.scrollIntoView({ block: "nearest" });
    }
  }

  // Highlight the edges touching the selected top-level card.
  function markPaths(top) {
    for (const p of pathEls) {
      const on = p.edge.from === top || p.edge.to === top;
      p.path.classList.toggle("active", on);
    }
  }

  // ---- edges -------------------------------------------------------------
  const wide = window.matchMedia("(min-width: 900px)");

  function draw() {
    for (const p of pathEls) p.path.remove();
    pathEls.length = 0;
    if (!wide.matches) return;

    const base = root.getBoundingClientRect();
    svg.setAttribute("viewBox", `0 0 ${base.width} ${base.height}`);
    // Measure every card once; the slot sort below would otherwise force a
    // layout read per comparison.
    const boxes = new Map();
    for (const [id, c] of card) {
      const r = c.getBoundingClientRect();
      boxes.set(id, { l: r.left - base.left, r: r.right - base.left, t: r.top - base.top, b: r.bottom - base.top });
    }
    const box = (id) => boxes.get(id);
    const cy = (id) => (box(id).t + box(id).b) / 2;
    const lane = (id) => laneIndex.get(nodes.get(id).lane);

    const cross = data.edges.filter((e) => lane(e.from) !== lane(e.to));
    const slot = (list, id, other, edge) => {
      const mine = list.filter((e) => e[id] === edge[id]).sort((a, b) => cy(a[other]) - cy(b[other]));
      return (mine.indexOf(edge) + 1) / (mine.length + 1);
    };

    for (const e of data.edges) {
      let d;
      const f = box(e.from);
      const t = box(e.to);
      if (lane(e.from) === lane(e.to)) {
        const down = f.t < t.t;
        const x = (f.l + f.r) / 2 + (down ? -14 : 14);
        const y1 = down ? f.b : f.t;
        const y2 = down ? t.t : t.b;
        d = `M${x},${y1} L${x},${y2}`;
      } else {
        const x1 = f.r;
        const x2 = t.l;
        const y1 = f.t + (f.b - f.t) * slot(cross, "from", "to", e);
        const y2 = t.t + (t.b - t.t) * slot(cross, "to", "from", e);
        const dx = Math.max(24, (x2 - x1) / 2);
        d = `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`;
      }
      const path = svgEl("path", { d, "marker-end": "url(#arrow)" });
      svg.append(path);
      pathEls.push({ edge: e, path });
    }
    // Re-apply the highlight to the fresh paths only. Re-running select()
    // would rebuild the panel and drop focus from whatever the user is on.
    if (selectedId) markPaths(topOf(nodes.get(selectedId)));
  }

  new ResizeObserver(draw).observe(root);
  wide.addEventListener("change", draw);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(draw);

  // ---- tools strip -------------------------------------------------------
  const toolsEl = document.getElementById("tools-grid");
  if (toolsEl) {
    for (const t of data.tools) {
      const box = el("div", "tool");
      box.append(el("div", "name", t.id), richEl("p", null, t.summary));
      if (t.pairsWith.length) {
        const pairs = el("div", "pairs", "Use with ");
        t.pairsWith.forEach((p, i) => {
          if (i) pairs.append(", ");
          if (nodes.has(p)) {
            const b = el("button", null, p);
            b.type = "button";
            b.addEventListener("click", () => {
              // Narrow: the lanes stack tall, so bring the panel into view.
              // Wide: the map and panel fit together, so show the map.
              select(p, true);
              if (wide.matches) root.scrollIntoView({ block: "start" });
            });
            pairs.append(b);
          } else {
            pairs.append(el("code", null, p));
          }
        });
        box.append(pairs);
      }
      toolsEl.append(box);
    }
  }

  select("review-plan", false);
  draw();
})();
