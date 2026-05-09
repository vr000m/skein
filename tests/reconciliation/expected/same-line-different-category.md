{
  "summary": {
    "raw": 2,
    "merged": 0,
    "unique": 2,
    "related": 1
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "authz",
      "file": "src/api.py",
      "line": 88,
      "lenses": ["security"],
      "summary": "missing auth check",
      "evidence": "endpoint reachable without token",
      "suggestion": "add @require_auth"
    },
    {
      "severity": "Important",
      "category": "correctness",
      "file": "src/api.py",
      "line": 88,
      "lenses": ["logic"],
      "summary": "null deref",
      "evidence": "missing guard",
      "suggestion": "add check"
    }
  ],
  "related": [
    {
      "file": "src/api.py",
      "line": 88,
      "categories": ["authz", "correctness"]
    }
  ]
}
