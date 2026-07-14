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
      "severity": "Minor",
      "category": "factual",
      "file": "docs/dev_plans/example.md",
      "line": 200,
      "lenses": ["codebase-claims"],
      "summary": "plan claims a file exists that was not found",
      "evidence": "referenced path does not exist in the repo",
      "suggestion": "correct the path or remove the claim"
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
  "related": []
}
