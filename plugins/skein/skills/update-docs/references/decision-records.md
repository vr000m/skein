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

A comma-separated list of globs, each matched against a repo-relative path. The selector normalises each path first (a leading `./`, `.` components and repeated `/` are dropped), and refuses an absolute path or one with a `..` component rather than skipping it. The dialect is deliberately small, so it means the same thing on every bash:

- `*` matches any characters, including `/`, so `plugins/skein/*` matches every file under that directory.
- `?` matches exactly one character (one byte, case-sensitively, in every locale).
- Every other character is literal, and a glob may hold only letters, digits, spaces and `. _ / - @ + = : % ~` besides `*` and `?`. The validator rejects anything else (brackets, backslashes, braces, `!`, `(`, `)`, `$` and the like) and `**`.
- A glob is written in normal form: relative, no `./`, no `//`, no `.` or `..` components. The validator rejects any other spelling, which could never match a normalised path.
- A comma always separates two globs, and the spaces around each glob are trimmed.

`/review-plan` shows its architecture lens only the records whose globs match a path the plan names. `/deep-review` shows its architecture lens every active record, and the lens holds the code to a record only when one of the record's globs matches a file changed in the diff it reviews.

## Superseding a record

To replace a record, write the new one with `Supersedes: <old filename>`, then set the old record to `Status: superseded` and `Superseded by: <new filename>`. Each link must point to another record in this directory and agree in both directions. A succession chain cannot revisit a record, and an active record must have no successor. Amend an existing record only to fix a mistake. Write a new record when the decision changes.

## Pointing at a record from code

Where a comment would otherwise explain a design choice, point at the record instead: `see docs/decisions/<file>`.

## Validation

The validator that `/update-docs` bundles checks file types (the folder too: an unreadable one, or one reached through a linked `docs/`, fails), required headers, record status, reciprocal links, cycles, source plan containment, and supported `Applies to` globs. A repository without `docs/decisions/` passes, whether or not its `docs/` is a link. The selector that `/review-plan` and `/deep-review` bundle applies the same checks and shows reviewers only the records the validator accepts; when a record is malformed, or more records match than it can show, the review reports its decision coverage as degraded rather than claiming no decision applies. Before a promotion writes anything, `/update-docs` checks every path it would write and refuses while the existing records fail validation; the skill's own instructions give the details.
