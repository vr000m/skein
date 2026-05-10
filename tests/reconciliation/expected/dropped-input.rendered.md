**Reconciliation**: raw=2 merged=0 unique=2 related=0 dropped=1

### Critical
- **correctness**: divide by zero at src/x.py:7
  - Lenses: [logic]
  - Evidence: denominator unchecked
  - Suggestion: guard with if

### Important
- **input**: unvalidated arg at src/x.py:15
  - Lenses: [security]
  - Evidence: raw query string used
  - Suggestion: validate
