{
  "summary": {
    "raw": 2,
    "merged": 1,
    "unique": 1,
    "related": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "injection",
      "file": "src/db.py",
      "line": 17,
      "lenses": ["logic", "security"],
      "summary": "unsanitised input",
      "evidence": "user param interpolated",
      "suggestion": "use parameterised query"
    }
  ],
  "related": []
}
