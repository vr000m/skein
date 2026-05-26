# Spec Compliance Report Rubric

Gradeable criteria for evaluating a completed compliance report. Doubles as a Managed Agents outcome rubric and a local self-check before presenting the report to the user.

## Spec Resolution

- The spec reference resolved to a real, fetchable URL (RFC, draft, W3C/WHATWG spec, or direct link)
- The exact section under review is identified and linked
- IETF drafts that have been published as RFCs were redirected to the published RFC
- The fetched content is the actual spec section, not a guess or paraphrase

## Requirement Extraction

- Every normative RFC 2119 keyword in the section is captured (MUST, MUST NOT, SHALL, SHALL NOT, REQUIRED, SHOULD, SHOULD NOT, RECOMMENDED, MAY, OPTIONAL)
- Lowercase "must"/"should"/"may" are ignored per RFC 8174
- The total requirement count matches the breakdown in the summary table
- Each extracted requirement has a short identifier and the verbatim normative statement

## Per-Requirement Classification

- Every requirement is classified as exactly one of: Met / Missing / Partial / N/A
- "Met" findings cite a specific file path and line number with the relevant code snippet
- "Partial" findings explain the specific gap, not just "incomplete"
- "Missing" findings note that the codebase was searched (target file plus adjacent modules and tests)
- "N/A" findings explain why the requirement does not apply to this code's role
- Uncertain cases are classified as Partial, not Met

## Report Structure

- Status icons prefix every finding (✅ Met, ❌ Missing, ⚠️ Partial, ➖ N/A)
- Findings are grouped by requirement level (MUST first, then SHOULD, then MAY)
- Summary table includes all three rows (MUST/SHOULD/MAY) even when a level has zero requirements
- The spec section URL is linked
- No surrounding spec text is reproduced beyond the specific normative statement

## Scope Discipline

- The report covers exactly the spec section requested — no scope creep into adjacent sections
- No requirements were skipped because they "seemed unimportant"
- SHOULD and MAY requirements are reported, not dropped
