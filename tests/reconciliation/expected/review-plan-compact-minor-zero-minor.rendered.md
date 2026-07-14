**Reconciliation**: raw=2 merged=0 unique=2 related=0

### Critical
- **sequencing**: phase 4 depends on phase 6's output but runs first at docs/dev_plans/example.md:80
  - Lenses: [architecture]
  - Evidence: phase 4's impl files reference a script phase 6 creates
  - Suggestion: reorder phases or add an explicit forward-dependency note

### Important
- **unverified-claim**: plan assumes a config flag exists without checking at docs/dev_plans/example.md:112
  - Lenses: [assumptions]
  - Evidence: grep shows no such flag in the codebase
  - Suggestion: verify the flag exists or add a task to create it
