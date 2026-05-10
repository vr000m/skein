**Reconciliation**: raw=2 merged=1 unique=1 related=0

### Critical
- **correctness**: unbounded loop at src/foo.py:42
  - Lenses: [logic, security]
  - Evidence: may overrun buffer
  - Suggestion: bounds check
