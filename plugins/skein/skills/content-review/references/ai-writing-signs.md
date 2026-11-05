# AI-Writing Signs

Reference for `content-review` and `content-draft`. It lists patterns that make prose read as machine-generated, and how to fix them.

Source: Wikipedia's "Signs of AI writing" field guide (WikiProject AI Cleanup, https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing; Wikipedia text is available under CC BY-SA 4.0), adapted for TILs, blog posts, and technical docs. Wikipedia-only signs (citations, edit summaries, wikitext) are omitted. Last reviewed: 2026-11-05.

## How to use this

- **These are signals, not bans.** One hit is weak evidence. The finding is density: several distinct sign types in one paragraph, or one formula repeated through the piece.
- **Output is style feedback, not detection.** Never say or imply that a piece "is AI-written". Say that a passage reads as generic and show how to make it specific.
- **Fix by restoring the fact or deleting.** LLM prose regresses to the generic: a specific fact gets replaced by positive filler. Swapping one filler word for another only moves the tell. Either put the specific fact back, or cut the sentence.
- **If the fact is unknown, say so.** The reviewer must not invent it. Report the finding as `needs author input` and name what is missing (the number, the source, the command, the date).
- **Check the literal reading first.** "Underscore" can mean drawing a line; "landscape" can be a page orientation; "boasts" can be literal. Flag only the abstract, filler use.
- **Required structure is exempt.** A closing paragraph or section that the content type mandates (for example the forward-looking close in blog posts and TILs) is not a sign. Flag a closer only when it restates the piece without adding a next step, implication, or concrete follow-up.

## Severity

| Severity | When |
|----------|------|
| Critical | Assistant residue left in the published text (see below, including the exemptions), or an unresolved `[needs author input: ...]` marker |
| Important | 3 or more distinct sign types in one paragraph, or one structural formula repeated 3 or more times in the piece |
| Suggestion | Fewer than 3 distinct sign types in a paragraph (report one grouped finding naming each type), one structural formula repeated fewer than 3 times, a single independently reportable hit, or hedging disclaimers on their own; transition words alone are exempt |

Hedging disclaimers and vocabulary-only hits never count towards the 3-type Important threshold (see the notes on each).

## Assistant residue (Critical)

Text left over from a chat session. Remove it entirely.

- Chat openers and closers: "Certainly!", "Of course!", "I hope this helps", "Would you like me to...", "Let me know if...", "You're absolutely right".
- Knowledge-cutoff statements: "As of my last update", "Up to my last training".
- Refusals or apologies: "I'm sorry, but I can't...", "As an AI language model".
- Placeholders: `[Your Name]`, `[X]`, `{placeholder}`, `INSERT_..._HERE`, `Subject:` scaffolding, `2025-XX-XX`.
- Leaked scaffolding: "In this section, we will discuss...", "Here is a draft you can check before publishing".
- Leaked markup artefacts, such as `contentReference[...]` or a stray `---` divider that is not front matter.

Do not flag quoted examples (block quotes, inline code, fenced blocks), prose that discusses these phrases (for example a post about prompting or LLM tooling), a legitimate `---` horizontal rule or front-matter delimiter, or `[ ]` / `[x]` / `[X]` task-list items (a bare `[X]` outside a task list is still a placeholder). Flag only residue the author did not mean to publish. A leftover `[needs author input: ...]` marker (added deliberately by content-draft) is Critical because it must be resolved before publishing, but report it as an unresolved marker, not as an AI-writing sign.

## Content tells

The text gestures at importance instead of stating a fact.

| Sign | Examples | Usually fixed by |
|------|----------|------------------|
| Significance inflation | "stands as a testament to", "plays a pivotal role", "underscores the importance of", "setting the stage for", "leaves an indelible mark", "reflects broader trends" | State the actual consequence or number; otherwise delete |
| Trailing "-ing" analysis | "..., highlighting the need for X", "..., fostering collaboration", "..., ensuring reliability", "..., contributing to Y" | Cut the clause, or replace it with what specifically happened |
| Vague attribution | "experts argue", "industry reports suggest", "some critics say", "several sources" | Name the source, or drop the claim |
| Vague association | "associated with", "in connection with", "closely tied to" where a plain verb fits | Use the verb: "wrote", "maintains", "led", "broke" |
| Challenges-and-outlook formula | "Despite these challenges...", "Future outlook", a section that ends on a vague positive | State the real limitation and what you did about it, or cut the section |
| Canned notability | "featured in leading outlets", "active social media presence", "recognised as a leader" | Delete unless the claim is the point, in which case cite it |
| Superficial analysis | A paragraph that comments on significance without adding evidence, a decision, or a result | Replace with the evidence, or delete the paragraph |

## Language tells

| Sign | Examples | Usually fixed by |
|------|----------|------------------|
| Copulative avoidance | "serves as", "stands as", "functions as", "boasts", "features", "represents", "marks" used instead of "is" or "has" | Write "is" or "has" |
| Negative parallelism | "not just X, but Y", "not only X but also Y", "It's not X, it's Y", the same contrast spread over two sentences | State Y directly; keep the contrast only if X is a real misconception |
| Rule of three | Triple adjectives or triple short phrases that make an analysis look complete | Keep the items that carry evidence; drop the padding |
| Elegant variation | Rotating synonyms for one thing ("the tool", "the utility", "the solution") | Repeat the plain noun |
| Section-summary closer | "In summary", "In conclusion", "Overall", a last paragraph that restates the piece | End on the last substantive point or the next step |
| Sentence-initial "Additionally" / "Moreover" | Used as a connective with no logical work to do | Supporting evidence only: never report it in isolation; when another sign establishes a finding, delete it or state the relationship ("Because...", "That also...") |

Notes:

- Negative parallelism also appears in human "myths busted" lists. Weigh it with other signs.
- Transition words alone ("Additionally", "Consequently", "Notably") are common in human essays. Do not flag them in isolation.

## Style tells

Count a style tell only when it is not required by the target format.

- **Emoji** at the start of headings or list items.
- **Bold-header bullet lists**: a list where every item opens with a bolded label ("**Speed:** ...", "**Cost:** ..."). Flag repeated use; one such list that is genuinely a glossary or comparison is fine.
- **Mechanical boldface**: key phrases bolded at random through running prose, not as a label, a first-use term, or a required marker. One or two deliberate bolds are fine; flag repeated use.
- **Title Case headings** where the surrounding site or document uses sentence case.
- **Curly quotes and apostrophes** (`“ ” ’`): flag only when the rest of the file uses straight quotes. Editors and CMSes often convert quotes automatically, so a uniformly curly file is not a finding.
- **Heading structure errors**: a level-1 heading in the body of a post that already has a title, or several level-1 headings.
- **Uniform rhythm**: sentences all of similar length (roughly 8 to 20 words) and the same comma-and-full-stop punctuation throughout, with no fragments, parentheses, or asides. Weak on its own; supporting evidence only.
- **Em dashes**: no longer a tell on their own. Newer models are tuned to avoid them, and plenty of careful human writers use them. Flag only (a) spaced em dashes (` — `) in a house style that uses unspaced ones, and (b) an em dash used as a comma substitute in a sentence that would read fine with a comma or full stop. Do not recommend an em dash as a comma-splice fix; use a full stop, semicolon, or conjunction.

Required structure is exempt: the `**TL;DR:**` line, headings mandated by the content type, and fenced code blocks.

## Hedging disclaimers

Weakest category. Report as Suggestion only, and never count towards the Important threshold.

- Source-availability hedges: "details are limited", "not widely documented", "based on available information".
- Didactic hedges: "it's important to note that...", "it is worth noting".
- Corrective framings (common since mid-2026): "X does not establish Y", "should not be confused with", and "rather than" used to correct an unstated misreading (hedging, not negative parallelism; it never counts towards the Important threshold).

Keep a hedge when the uncertainty is real and material; say what is uncertain and why.

## Dated vocabulary

Words LLM output over-uses, by approximate period. The buckets are guides, not cut-offs. Vocabulary alone never makes a finding above Suggestion; use it to decide where to look.

| Period | Words |
|--------|-------|
| 2023 to mid-2024 | delve, tapestry, testament, intricate / intricacies, landscape (abstract), vibrant, meticulously, interplay |
| Mid-2024 to mid-2025 | align with, enhance, fostering, showcase / showcasing, garner, bolstered, enduring, robust |
| Mid-2025 to mid-2026 | emphasizing, highlighting, crucial, pivotal, valuable insights, boasts |
| Mid-2026 onward | multifaceted, universally, prioritise, challenge (as a noun in outlook sentences), leverage |

Weighting: the 2023 to mid-2024 bucket is a strong signal because human technical writers rarely use those words. The later buckets are weak signals because they contain ordinary engineering words such as "robust", "enhance", "align with", "enduring", "leverage", "challenge", and "prioritise". Flag those only when they sit inside one of the content or language patterns above ("leverage the power of...", "Despite these challenges..."), never on their own.

Overuse of one word does not imply its synonyms are overused. Do not build a ban list from this table.

## Not signs

These are poor indicators and must not be reported:

- Correct grammar and clean prose.
- Plain, simple, or "bland" prose.
- Formal or academic register.
- Transition words on their own.
- A single em dash, curly quote, or bullet list.
- Mixed registers, which often reflect a technical background or several authors.

Human writing is also becoming more LLM-like, and human judgment of AI text is close to chance. When in doubt, do not flag.

## Reporting a finding

Each finding gives the quoted passage, the sign type, and one of:

- a concrete rewrite that restores the specific fact (only when the fact is in the draft, the session context, or the repo); or
- `needs author input: <what is missing>`, with no invented content.

Example:

> Original: "The migration marks a pivotal step, highlighting the team's commitment to reliability."
> Sign types: significance inflation, trailing "-ing" analysis. Severity: Important only if 3 or more types appear in the paragraph; otherwise Suggestion.
> Fix: `needs author input: what the migration changed (command, table, or metric) and what broke or improved`. If the facts are known: "The migration moved 40 tables to Postgres 16 and cut nightly backup time from 52 to 9 minutes."
