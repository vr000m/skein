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
  - Lenses: [architecture]
  - Evidence: some functions raise, others return None on failure
  - Suggestion: pick one convention module-wide
- **docs**: docstring references removed parameter at src/util.py:30
  - Lenses: [docs]
  - Evidence: docstring still mentions old_arg
  - Suggestion: update docstring
  - Related findings: **style** Minor at same file:line
- **style**: unused variable tmp at src/util.py:30
  - Lenses: [logic]
  - Evidence: tmp assigned but never read
  - Suggestion: remove unused variable
  - Related findings: **docs** Minor at same file:line
