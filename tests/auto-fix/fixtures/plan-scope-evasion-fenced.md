# Task: Fenced Pseudo-Heading Evasion

## Objective

A fenced code block containing a line that looks like a heading must NOT be
treated as a heading by the scope detector.

## Implementation Checklist

```
## Requirements
```

Line after the fenced pseudo-heading. The deepest enclosing real heading is
`## Implementation Checklist` (not `## Requirements`), so the line is
ordinary prose — auto-fix may apply here.

### Phase 1: Stub
