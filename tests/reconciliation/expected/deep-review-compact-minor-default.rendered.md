**Reconciliation**: raw=5 merged=0 unique=5 related=1

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

### Minor
- **consistency**: inconsistent error-handling convention across the module
- **docs**: docstring references removed parameter (src/util.py:30) — see also style at same location
- **style**: unused variable tmp (src/util.py:30) — see also docs at same location
