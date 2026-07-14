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
      "category": "authz",
      "file": "src/api.py",
      "line": 42,
      "lenses": ["security"],
      "summary": "missing auth check",
      "evidence": "endpoint reachable without token",
      "suggestion": "add @require_auth"
    },
    {
      "severity": "Important",
      "category": "correctness",
      "file": "src/util.py",
      "line": 18,
      "lenses": ["logic"],
      "summary": "off-by-one in loop bound",
      "evidence": "range(0, n) should be range(0, n+1)",
      "suggestion": "fix loop bound"
    },
    {
      "severity": "Minor",
      "category": "consistency",
      "file": "",
      "line": -1,
      "lenses": ["architecture"],
      "summary": "inconsistent error-handling convention across the module",
      "evidence": "some functions raise, others return None on failure",
      "suggestion": "pick one convention module-wide"
    },
    {
      "severity": "Minor",
      "category": "docs",
      "file": "src/util.py",
      "line": 30,
      "lenses": ["docs"],
      "summary": "docstring references removed parameter",
      "evidence": "docstring still mentions old_arg",
      "suggestion": "update docstring"
    },
    {
      "severity": "Minor",
      "category": "style",
      "file": "src/util.py",
      "line": 30,
      "lenses": ["logic"],
      "summary": "unused variable tmp",
      "evidence": "tmp assigned but never read",
      "suggestion": "remove unused variable"
    }
  ],
  "related": [
    {
      "file": "src/util.py",
      "line": 30,
      "categories": ["docs", "style"]
    }
  ]
}
