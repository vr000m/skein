# Task: Horizontal Rule Evasion

## Objective

A `---` between a forbidden heading and the target line is NOT a heading and
must not reset the deepest enclosing heading.

## Requirements

Initial requirements line.

---

Line after a horizontal rule. The detector must still resolve to
`## Requirements`, not treat `---` as a section break.

## Implementation Checklist

### Phase 1: Stub
