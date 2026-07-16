**Reconciliation**: raw=2 merged=0 unique=2 related=0

### Critical
- **authz**: missing auth check at src/api.py:42
  - Lenses: [security]
  - Evidence: endpoint reachable without token
  - Suggestion: add @require_auth

### Important
- **correctness**: off-by-one in loop bound at src/util.py:18
  - Lenses: [logic]
  - Evidence: range(0, n) should be range(0, n+1)
  - Suggestion: fix loop bound
