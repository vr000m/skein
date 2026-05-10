**Reconciliation**: raw=1 merged=0 unique=1 related=0

### Important
- **correctness**: off-by-one at src/foo.py:42
  - Lenses: [logic]
  - Evidence: loop runs N+1 times
  - Suggestion: use range(N)
