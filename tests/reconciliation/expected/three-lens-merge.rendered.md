**Reconciliation**: raw=3 merged=1 unique=1 related=0

### Important
- **coupling**: tight coupling at src/svc.py:99
  - Lenses: [architecture, logic, security]
  - Evidence: direct import of impl
  - Suggestion: introduce interface
