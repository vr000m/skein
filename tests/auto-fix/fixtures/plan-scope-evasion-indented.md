# Task: Indented Heading Evasion

## Objective

A leading-whitespace heading should NOT count as a real heading. The detector
must walk up and find the nearest *column-zero* forbidden heading.

## Requirements

Sample line inside Requirements zone.

  ## Looks-Like-Heading-But-Indented

This line follows an indented pseudo-heading. The deepest enclosing
column-zero heading is still `## Requirements`, so a fix here must be
rejected as `rejected_scope`.

## Implementation Checklist

### Phase 1: Stub
