# spec-compliance-check Skill

| Field | Value |
|-------|-------|
| **Status** | Complete |
| **Component** | spec-skills |
| **Priority** | Medium |
| **Branch** | `feat/rfc-finder-skill` |
| **Created** | 2026-03-13 |
| **Objective** | Create matching Claude and Codex skills that check whether code complies with a referenced specification (IETF RFC, W3C spec, IETF draft, or similar standards body document) |

## Context

The `rfc-finder` skill finds and links to IETF RFCs. This new skill addresses the next step: given code that claims to implement a spec section, verify whether the implementation actually covers the normative requirements. This is a common need in protocol/standards work where implementations must conform to MUST/SHOULD/MAY requirements (RFC 2119).

Scope covers any standards body document accessible via public URL: IETF RFCs, IETF drafts, W3C specs, WHATWG specs, etc. The repo now needs the same workflow expressed for both Claude and Codex, with only runtime-specific tool instructions differing.

## Requirements

1. Accept code (file path or inline) + spec reference (RFC number, URL, or draft name + section)
2. Fetch the referenced spec section via `WebSearch`/`WebFetch`
3. Extract normative requirements (MUST, MUST NOT, SHOULD, SHOULD NOT, MAY per RFC 2119)
4. Map each requirement against the code
5. Return a structured compliance report
6. Handle multiple spec sources: IETF (datatracker/rfc-editor), W3C (w3.org), WHATWG (spec.whatwg.org), etc.
7. Must not reproduce large blocks of spec text — quote only the specific normative statement being checked

## Implementation Checklist

### Phase 1: Create skill file

- [x] Create `.claude/skills/spec-compliance/SKILL.md` with frontmatter and body
- [x] Create `.codex/skills/spec-compliance/SKILL.md` with frontmatter and body
- [x] Add `spec-compliance` to `MANAGED_SKILLS` in all 4 scripts (`promote-skills.sh`, `sync-skills.sh`, `bootstrap-skills.sh`, `check-sync.sh`)

### Phase 2: Skill content

- [x] Frontmatter: name, description (trigger on "compliance", "conformance", "does this code follow", "check against spec", "RFC 2119"), argument-hint
- [x] Step 1: Parse the input — identify code source and spec reference
- [x] Step 2: Resolve the spec — map reference to fetchable URL, handle RFC numbers, draft names, W3C spec URLs
- [x] Step 3: Fetch and extract — load the spec section, identify normative language (RFC 2119 keywords)
- [x] Step 4: Analyse code — map each requirement to code evidence (met, missing, partial, N/A)
- [x] Step 5: Return structured report
- [x] Edge cases: spec section not found, no normative language, code too large, ambiguous spec reference
- [x] Examples: 1 (RFC 4585 Section 6.2.1 — Generic NACK)
- [x] Codex adaptation: replace Claude-specific browsing/reading tools with `search_query`, `open`, `find`, `rg`, and line-number inspection commands

## Technical Specifications

### Files to Create
- `.claude/skills/spec-compliance/SKILL.md`
- `.codex/skills/spec-compliance/SKILL.md`

### Files to Modify
- `scripts/promote-skills.sh` — add `spec-compliance` to `MANAGED_SKILLS`
- `scripts/sync-skills.sh` — add `spec-compliance` to `MANAGED_SKILLS`
- `scripts/bootstrap-skills.sh` — add `spec-compliance` to `MANAGED_SKILLS`
- `scripts/check-sync.sh` — add `spec-compliance` to `MANAGED_SKILLS`

### Output Format

```
## Spec Compliance Report

**Code**: `path/to/file.py` (lines 30-85)
**Spec**: RFC 4585, Section 6.2.1 — "Generic NACK"
**Requirements found**: N total (X MUST, Y SHOULD, Z MAY)

### MUST Requirements
1. ✅ **Met** — "MUST set PT=RTPFB and FMT=1"
   Evidence: line 42 — `packet.pt = RTPFB; packet.fmt = 1;`
2. ❌ **Missing** — "MUST include at least one NACK FCI"
   No FCI construction found in the code path.
3. ⚠️ **Partial** — "MUST NOT send NACK for packets outside the window"
   Window check exists (line 58) but only covers forward direction.

### SHOULD Requirements
...

### MAY Requirements
...

### Summary
- MUST: X/Y met
- SHOULD: X/Y met
- MAY: X/Y met (informational — MAY items are optional)
```

### Spec Source Resolution

| Reference format | Resolution |
|---|---|
| `RFC XXXX` or `rfc XXXX` | `https://www.rfc-editor.org/rfc/rfcXXXX` |
| `RFC XXXX Section X.Y` | Fetch RFC, navigate to section |
| `draft-ietf-*` | `https://datatracker.ietf.org/doc/draft-name/` |
| `https://...` (direct URL) | Fetch directly |
| W3C spec name (e.g., "WebRTC 1.0") | `WebSearch` to find spec URL on w3.org |

### Tools Used
- `WebSearch` — resolve spec references to URLs
- `WebFetch` — fetch spec section content
- `Read` — read the code file(s)
- `Grep` — search code for specific patterns matching requirements

Codex counterpart:
- `search_query` — resolve named specs on official domains only
- `open` / `find` — fetch spec sections and navigate to headings or anchors
- `rg` / `nl -ba` / `sed -n` — inspect code and capture line-number evidence

## Testing Notes

Test with:
1. `/spec-compliance path/to/nack.py RFC 4585 Section 6.2.1` — IETF RFC
2. `/spec-compliance path/to/peer.js "W3C WebRTC 1.0" Section 4.4.1` — W3C spec
3. Edge case: spec section that has no normative language
4. Edge case: code file that doesn't exist

## Acceptance Criteria

- [ ] Skill triggers on compliance/conformance queries
- [ ] Handles IETF RFCs, IETF drafts, W3C specs, and direct URLs
- [ ] Extracts RFC 2119 normative language correctly
- [ ] Maps requirements to code with line-number evidence
- [ ] Output format is structured and scannable
- [ ] Does not reproduce large blocks of spec text
- [ ] Added to all 4 managed-skills scripts
- [ ] Examples are factually correct (verified via WebFetch)
- [ ] Claude and Codex versions differ only where the runtime tool surface requires it

## Issues & Solutions

- Claude and Codex do not share the same browsing or file-inspection tool surface.
  Solution: keep the workflow and reporting format aligned, but express spec resolution and code inspection in runtime-specific terms for each skill.

## Final Results

- Added `.claude/skills/spec-compliance/SKILL.md` for Claude Code.
- Added `.codex/skills/spec-compliance/SKILL.md` for Codex with equivalent workflow and Codex-native tool guidance.
- Kept the report shape, examples, edge cases, and RFC 2119 / RFC 8174 handling aligned across both skills.
