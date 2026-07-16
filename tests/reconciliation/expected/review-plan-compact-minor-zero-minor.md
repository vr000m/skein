{
  "schema_version": 2,
  "summary": {
    "raw": 2,
    "merged": 0,
    "unique": 2,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "sequencing",
      "file": "docs/dev_plans/example.md",
      "line": 80,
      "lenses": ["architecture"],
      "summary": "phase 4 depends on phase 6's output but runs first",
      "evidence": "phase 4's impl files reference a script phase 6 creates",
      "suggestion": "reorder phases or add an explicit forward-dependency note"
    },
    {
      "severity": "Important",
      "category": "unverified-claim",
      "file": "docs/dev_plans/example.md",
      "line": 112,
      "lenses": ["assumptions"],
      "summary": "plan assumes a config flag exists without checking",
      "evidence": "grep shows no such flag in the codebase",
      "suggestion": "verify the flag exists or add a task to create it"
    }
  ],
  "related": []
}
