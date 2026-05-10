**Reconciliation**: raw=2 merged=0 unique=2 related=1

### Critical
- **authz**: missing auth check at src/api.py:88
  - Lenses: [security]
  - Evidence: endpoint reachable without token
  - Suggestion: add @require_auth
  - Related findings: **correctness** Important at same file:line

### Important
- **correctness**: null deref at src/api.py:88
  - Lenses: [logic]
  - Evidence: missing guard
  - Suggestion: add check
  - Related findings: **authz** Critical at same file:line
