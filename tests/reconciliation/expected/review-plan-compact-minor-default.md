{
  "schema_version": 2,
  "summary": {
    "raw": 5,
    "merged": 0,
    "unique": 5,
    "related": 1,
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
    },
    {
      "severity": "Minor",
      "category": "factual",
      "file": "docs/dev_plans/example.md",
      "line": 150,
      "lenses": ["codebase-claims"],
      "summary": "plan claims a file exists that was not found",
      "evidence": "referenced path does not exist in the repo",
      "suggestion": "correct the path or remove the claim"
    },
    {
      "severity": "Minor",
      "category": "scope",
      "file": "",
      "line": -1,
      "lenses": ["architecture"],
      "summary": "plan does not state whether skein-codex is in scope for this change",
      "evidence": "no mention of skein-codex anywhere in the plan",
      "suggestion": "add an explicit scope statement"
    },
    {
      "severity": "Minor",
      "category": "testing",
      "file": "docs/dev_plans/example.md",
      "line": 150,
      "lenses": ["spec-and-testing"],
      "summary": "phase has no explicit test command",
      "evidence": "Test command field is blank",
      "suggestion": "add a concrete test command"
    }
  ],
  "related": [
    {
      "file": "docs/dev_plans/example.md",
      "line": 150,
      "categories": ["factual", "testing"]
    }
  ]
}
