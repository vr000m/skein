{
  "schema_version": 2,
  "summary": {
    "raw": 6,
    "merged": 0,
    "unique": 6,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "logic",
      "file": "src/a.py",
      "line": 1,
      "lenses": ["logic"],
      "summary": "would_apply control",
      "evidence": "control evidence",
      "suggestion": "control suggestion",
      "auto_fix": {"kind": "unused_import", "before": "x", "after": "y", "scope": "file"},
      "auto_fix_status": "would_apply"
    },
    {
      "severity": "Important",
      "category": "logic",
      "file": "src/b.py",
      "line": 2,
      "lenses": ["logic"],
      "summary": "rejected_kind not annotated",
      "evidence": "kind outside allowlist",
      "suggestion": "drop kind",
      "auto_fix": {"kind": "refactor_method", "before": "x", "after": "y", "scope": "file"},
      "auto_fix_status": "rejected_kind"
    },
    {
      "severity": "Important",
      "category": "logic",
      "file": "src/c.py",
      "line": 3,
      "lenses": ["logic"],
      "summary": "rejected_kind_scope not annotated",
      "evidence": "scope outside docstring",
      "suggestion": "narrow scope",
      "auto_fix": {"kind": "docstring_typo", "before": "x", "after": "y", "scope": "file"},
      "auto_fix_status": "rejected_kind_scope"
    },
    {
      "severity": "Important",
      "category": "logic",
      "file": "src/d.py",
      "line": 4,
      "lenses": ["logic"],
      "summary": "rejected_semantic_change not annotated",
      "evidence": "symbol set differs",
      "suggestion": "manual review",
      "auto_fix": {"kind": "import_sort", "before": "x", "after": "y", "scope": "file"},
      "auto_fix_status": "rejected_semantic_change"
    },
    {
      "severity": "Important",
      "category": "logic",
      "file": "plan.md",
      "line": 5,
      "lenses": ["prose"],
      "summary": "rejected_path not annotated",
      "evidence": "scope mismatch",
      "suggestion": "check path binding",
      "auto_fix": {"kind": "prose_typo", "before": "x", "after": "y", "scope": "plan.md:5"},
      "auto_fix_status": "rejected_path"
    },
    {
      "severity": "Minor",
      "category": "scope",
      "file": "plan.md",
      "line": 6,
      "lenses": ["prose"],
      "summary": "rejected_drift not annotated",
      "evidence": "cited line drifted",
      "suggestion": "re-anchor",
      "auto_fix": {"kind": "prose_typo", "before": "x", "after": "y", "scope": "plan.md:6"},
      "auto_fix_status": "rejected_drift"
    }
  ],
  "related": []
}
