**Reconciliation**: raw=6 merged=1 unique=4 related=1

### Critical
- **Assumption**: Architecture Decisions assumes an async queue at docs/dev_plans/example-plan.md:42
  - Lenses: [architecture, sequencing]
  - Evidence: plan line 42 references a shared async queue
  - Suggestion: adopt an async queue for cross-worker communication
  - Related findings: **Contradiction** Critical at same file:line
- **Contradiction**: Architecture Decisions assumes an async queue while Requirements commits to synchronous processing at docs/dev_plans/example-plan.md:42
  - Lenses: [contradiction]
  - Evidence: plan line 42 (Architecture Decisions: async queue) vs plan line 42 (Requirements: synchronous processing)
  - Suggestion: pick one processing model and align both sections
  - Related findings: **Assumption** Critical at same file:line

### Important
- **Contradiction**: Two lenses propose mutually exclusive fixes with no shared plan-line anchor
  - Lenses: [contradiction]
  - Evidence: architecture lens suggestion vs sequencing lens suggestion, no common plan line to anchor on
  - Suggestion: resolve which lens's fix takes precedence

### Minor
- **Contradiction**: A second, unrelated plan-internal contradiction with no shared anchor
- **Nonexistent Reference**: plan references a script that does not exist (scripts/nonexistent-script.sh:10)
