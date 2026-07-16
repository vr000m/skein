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
    }
  ],
  "related": []
}
