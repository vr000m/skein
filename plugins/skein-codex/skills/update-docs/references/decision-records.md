# Decision records

A decision record is a short file that states one long-lived architecture decision, why it was made, and which paths it constrains. Dev plans hold decisions while the work is in flight; a record is where a decision lives once it has shipped.

Any repository that uses skein may adopt this folder. The first approved promotion creates it. Until then `scripts/decisions-active.sh` prints nothing and `scripts/check-decisions.sh` passes.

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

The body sections are short: one paragraph for the decision, the reasons, the options that were weighed and dropped, and what now follows from it.

## `Applies to` globs

A comma-separated list of globs, each matched against a repo-relative path with bash `[[ $path == $glob ]]` semantics:

- `*` matches any characters, including `/`, so `plugins/skein/*` matches every file under that directory.
- `?` and `[...]` behave as in bash.
- `**` and braces (`{a,b}`) are not supported, and the validator rejects them.

A record whose globs match none of the paths under review is not shown to the reviewers.

## Superseding a record

To replace a record, write the new one with `Supersedes: <old filename>`, then set the old record to `Status: superseded` and `Superseded by: <new filename>`. The links must agree in both directions, and an active record must not name a successor. Amend a record only to fix a mistake; a changed decision is a new record.

## Pointing at a record from code

Where a comment would otherwise explain a design choice, point at the record instead: `see docs/decisions/<file>`.

## Validation

`scripts/check-decisions.sh [<repo-root>]` checks the folder: required headers, a valid `Status`, resolving and reciprocal supersession links, no active record that is superseded, a resolving `Source plan`, and supported `Applies to` globs. `just ci` runs it.
