**Reconciliation**: raw=2 merged=1 unique=1 related=0

### Critical
- **injection**: sql concatenation at src/db.py:17
  - Lenses: [logic, security]
  - Evidence: string concat with user input
  - Suggestion: prepared statement
