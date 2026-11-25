# Decision records

A decision record is a short file that states one long-lived architecture decision, why it was made, and which paths it constrains. Dev plans hold decisions while the work is in flight; a record is where a decision lives once it has shipped.

Any repository that uses skein may adopt this folder. The first approved promotion creates it. Until then the decision selector that `/review-plan` and `/deep-review` bundle prints nothing, and the validator bundled with `/update-docs` passes.

## When a decision gets a record

Promote a decision when it does at least one of these:

- It spans more than one file or component.
- It is expected to outlive the plan that made it.
- It constrains future work, so a later change could contradict it by accident.

Do not promote a local implementation detail, a choice that the code already makes obvious, or a plan's task list.

`/update-docs` offers promotion after reviews converge. It reads the plan's `### Architecture Decisions` section and any decision copied into its `## Findings`. Nothing is written until you approve the offer for that record.

## Record format

One file per decision, named `yyyymmdd-slug.md` (the date is the day the record is created). The header is inline `**Field**: value` lines, with no YAML frontmatter, matching the dev-plan convention. Every field is required.

```
# <Decision title>

**Status**: active | superseded
**Date**: YYYY-MM-DD
**Applies to**: <comma-separated path globs>
**Supersedes**: <record filename> | none
**Superseded by**: <record filename> | none
**Source plan**: <docs/dev_plans/... file>

## Decision
## Why
## Alternatives rejected
## Consequences
```

| Field | Meaning |
|---|---|
| `Status` | `active` or `superseded`. Only active records are checked against new plans and diffs. |
| `Date` | When the record was written. |
| `Applies to` | Which paths the decision constrains; see below. |
| `Supersedes` | The record this one replaces, or `none`. |
| `Superseded by` | The record that replaces this one, or `none`. |
| `Source plan` | The dev plan the decision came from, as a repo-relative path that exists. |

Store each record as a regular Markdown file inside this directory. A record's `Source plan` may be a symlink if it resolves inside the same repository, but a promotion writes to its source plan, so promoting needs a plan that is not a symlink: the write preflight refuses a symlinked plan.

The body sections are short: one paragraph for the decision, the reasons, the options that were weighed and dropped, and what now follows from it.

## `Applies to` globs

A comma-separated list of globs, each matched against a repo-relative path with bash `[[ $path == $glob ]]` semantics:

- `*` matches any characters, including `/`, so `plugins/skein/*` matches every file under that directory.
- `?` and `[...]` behave as in bash, matching bytes: a range such as `[a-c]` is case-sensitive and the same in every locale.
- A comma separates two globs, except inside a bracket expression or after a backslash: `src/file[_,].py` is one glob matching `src/file_.py` and `src/file,.py`, and `docs/a\,b.md` matches `docs/a,b.md`.
- `**`, braces (`{a,b}`) and the extended patterns `?(...)`, `*(...)`, `+(...)`, `@(...)` and `!(...)` are not supported, and the validator rejects them. Bash honours the extended patterns inside `[[ == ]]` whatever the `extglob` option says, so a literal such as `docs/*(draft).md` would silently change meaning. Inside a bracket expression or after a backslash these characters are literal, so `file[?(].txt` and `x[**]y` are accepted.
- Surrounding spaces are trimmed, except an escaped one: `docs/foo\ ` ends in a space.

A record whose globs match none of the paths under review is not shown to the reviewers.

## Superseding a record

To replace a record, write the new one with `Supersedes: <old filename>`, then set the old record to `Status: superseded` and `Superseded by: <new filename>`. Each link must point to another record in this directory and agree in both directions. A succession chain cannot revisit a record, and an active record must have no successor. Amend an existing record only to fix a mistake. Write a new record when the decision changes.

## Pointing at a record from code

Where a comment would otherwise explain a design choice, point at the record instead: `see docs/decisions/<file>`.

## Validation

The validator `/update-docs` bundles, `check-decisions.sh [<repo-root>]`, checks file types (the folder too: an unreadable one fails), required headers, record status, reciprocal links, cycles, source plan containment, and supported `Applies to` globs. The selector `/review-plan` and `/deep-review` bundle, `decisions-active.sh`, applies the same checks and selects only records the validator accepts. Before a promotion offers or writes a record, `/update-docs` checks each file name against the rule below and runs `check-decisions.sh --targets-file -` over every path it would write, the paths arriving on standard input rather than the command line. Each path must be `docs/dev_plans/<name>` (the source plan) or `docs/decisions/<name>`, where `<name>` is a single path component matching `[A-Za-z0-9][A-Za-z0-9._-]*[.]md`: no further `/`, no `.git` component, no leading `-` or `.`. No component may be a symlink, and an existing path must be a regular file. The whole record graph is still validated, and the exit status tells the failures apart: `0` valid, `1` the existing records have a problem (every target is safe), `2` usage error, `3` at least one target is unsafe. A valid record set is a precondition of every promotion: on exit `1`, fix the reported records first.
