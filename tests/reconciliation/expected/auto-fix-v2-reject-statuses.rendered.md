**Reconciliation**: raw=6 merged=0 unique=6 related=0

### Critical
- **logic** [AUTO-FIXABLE]: would_apply control at src/a.py:1
  - Lenses: [logic]
  - Evidence: control evidence
  - Suggestion: control suggestion

### Important
- **logic**: rejected_kind not annotated at src/b.py:2
  - Lenses: [logic]
  - Evidence: kind outside allowlist
  - Suggestion: drop kind
- **logic**: rejected_kind_scope not annotated at src/c.py:3
  - Lenses: [logic]
  - Evidence: scope outside docstring
  - Suggestion: narrow scope
- **logic**: rejected_semantic_change not annotated at src/d.py:4
  - Lenses: [logic]
  - Evidence: symbol set differs
  - Suggestion: manual review
- **logic**: rejected_path not annotated at plan.md:5
  - Lenses: [prose]
  - Evidence: scope mismatch
  - Suggestion: check path binding

### Minor
- **scope**: rejected_drift not annotated at plan.md:6
  - Lenses: [prose]
  - Evidence: cited line drifted
  - Suggestion: re-anchor
