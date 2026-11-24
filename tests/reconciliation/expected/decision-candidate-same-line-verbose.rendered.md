**Reconciliation**: raw=3 merged=0 unique=3 related=1

### Critical
- **Security**: token logged at a.py:3
  - Lenses: [security]
  - Evidence: print(token)
  - Suggestion: drop the print
  - Related findings: **Documentation** Important at same file:line

### Important
- **Documentation**: Excuse: comment defers the fix at a.py:3
  - Lenses: [documentation]
  - Evidence: # TODO later
  - Suggestion: fix it now
  - Related findings: **Security** Critical at same file:line

### Minor
- **Documentation**: Decision candidate: chose a 3-retry bound at a.py:3
  - Lenses: [documentation]
  - Evidence: # three retries
  - Suggestion: record the decision
