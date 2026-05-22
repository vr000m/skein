# rfc-finder Skill

| Field | Value |
|-------|-------|
| **Status** | Complete |
| **Component** | spec-skills |
| **Priority** | Medium |
| **Branch** | `feat/rfc-finder-skill` |
| **Created** | 2026-03-13 |
| **Completed** | 2026-03-13 |
| **Objective** | Create a Claude Code skill that finds and links to IETF RFCs by topic, protocol, code context, or RFC number |

## Context

When working on protocol implementations, developers frequently need to find the relevant IETF RFC or draft. This skill automates that lookup — given a topic, protocol name, code snippet, or RFC number, it searches IETF Datatracker and RFC Editor, verifies results, and returns structured links with factual annotations.

## Requirements

1. Find RFCs by direct topic, code inference, protocol family, or specific RFC number
2. Search via `WebSearch` (Datatracker, RFC Editor) and verify via `WebFetch`
3. Handle the draft-to-RFC lifecycle (drafts that became RFCs, widely-deployed drafts that never did)
4. Return structured output with title, status, relevant section, and obsolescence info
5. Never fabricate RFC numbers — always verify via search
6. Follow project skill conventions (frontmatter, argument-hint, file location)

## Implementation Checklist

### Phase 1: Initial skill
- [x] Create `.claude/skills/rfc-finder/SKILL.md` with frontmatter and 3-step workflow
- [x] Add Usage section with invocation examples
- [x] Add edge cases (no results, invalid RFC, ambiguous query, obsoleted RFCs)
- [x] Add verified examples (WebRTC congestion control, sendNack())

### Phase 2: Review fixes — Codex feedback
- [x] Tighten description to avoid over-triggering on non-IETF requests
- [x] Clarify summarization policy (brief annotations OK, paraphrasing not)
- [x] Re-add protocol names scoped behind "asks about the spec behind a protocol"
- [x] Quote argument-hint to prevent YAML parsing issues

### Phase 3: Review fixes — Codex-inspired improvements
- [x] Use "Internet-Draft" / "Expired Internet-Draft" labels (not "Draft (widely deployed)")
- [x] Add guardrail against unverified ecosystem adoption claims
- [x] Tighten draft inclusion criteria
- [x] Make example notes more factual, less editorial

### Phase 4: Script integration
- [x] Add `rfc-finder` to `MANAGED_SKILLS` in `promote-skills.sh`
- [x] Add `rfc-finder` to `MANAGED_SKILLS` in `sync-skills.sh`
- [x] Add `rfc-finder` to `MANAGED_SKILLS` in `bootstrap-skills.sh`
- [x] Add `rfc-finder` to `MANAGED_SKILLS` in `check-sync.sh`

### Phase 5: Code review fixes
- [x] Fix RFC 8888 section title ("RTCP Feedback for Congestion Control")
- [x] Use full title for RFC 8698 (NADA) and RFC 4585 (RTP/AVPF)
- [x] Enumerate all IETF status labels in format template
- [x] Add Relevant section field to draft format block
- [x] Remove misplaced affirmative rule from "What NOT to Do" list
- [x] Use square-bracket argument-hint convention to match sibling skills

## Technical Specifications

### Files Created
- `.claude/skills/rfc-finder/SKILL.md`

### Files Modified
- `scripts/promote-skills.sh` — added `rfc-finder` to `MANAGED_SKILLS`
- `scripts/sync-skills.sh` — added `rfc-finder` to `MANAGED_SKILLS`
- `scripts/bootstrap-skills.sh` — added `rfc-finder` to `MANAGED_SKILLS`
- `scripts/check-sync.sh` — added `rfc-finder` to `MANAGED_SKILLS`

### Files Removed
- `rfc-finder/SKILL.md` — original misplaced location at repo root

## Testing Notes

Verified factual accuracy of all example RFC data via `WebFetch` against Datatracker:

| Item | Verified |
|------|----------|
| `draft-ietf-rmcat-gcc` — Expired, never became RFC | ✅ |
| RFC 8836 — Informational | ✅ |
| RFC 8888 — Proposed Standard, Section 3 title | ✅ |
| RFC 8698 — Experimental, full NADA title | ✅ |
| RFC 4585 — Proposed Standard, updated by 5506 & 8108 | ✅ |
| RFC 5104 — Proposed Standard, defines FIR (not PLI) | ✅ |

Functional test: invoked `/rfc-finder WebRTC congestion control` — skill triggered correctly, loaded instructions, produced accurate results.

## Issues & Solutions

| Issue | Solution |
|-------|----------|
| Skill placed at `rfc-finder/SKILL.md` (repo root) | Moved to `.claude/skills/rfc-finder/SKILL.md` |
| Description too broad, over-triggers on generic "protocol" mentions | Scoped protocol list behind "asks about the spec behind a protocol" |
| "Never summarize" contradicted by Note fields in examples | Clarified: brief factual annotations OK, paraphrasing substance is not |
| "Draft (widely deployed)" makes unverifiable adoption claims | Changed to "Internet-Draft" / "Expired Internet-Draft" from Datatracker metadata |
| Example RFC titles truncated vs official titles | Used full titles from rfc-editor.org |
| `<angle bracket>` argument-hint inconsistent with sibling skills | Changed to `[square bracket]` convention |

## Final Results

Skill is functional and verified. All example data confirmed against Datatracker. Integrated into promote/sync/bootstrap/check-sync scripts. Ready for PR.
