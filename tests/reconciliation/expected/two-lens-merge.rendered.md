**Reconciliation**: raw=2 merged=1 unique=1 related=0

### Critical
- **injection**: unsanitised input at src/db.py:17
  - Lenses: [logic, security]
  - Evidence: user param interpolated
  - Suggestion: use parameterised query
