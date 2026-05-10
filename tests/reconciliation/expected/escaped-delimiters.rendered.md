**Reconciliation**: raw=2 merged=1 unique=0 related=0

### Critical
- **parser**: handles brackets [] and braces {} with slash \ and quote " at src/[weird]{file}.py:42
  - Lenses: [logic, security]
  - Evidence: array [ marker ] object { marker } combo \" ] } [ { end
  - Suggestion: preserve backslash \ and quoted " text
