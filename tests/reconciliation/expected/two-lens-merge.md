{
  "schema_version": 2,
  "summary": {
    "raw": 2,
    "merged": 1,
    "unique": 0,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "injection",
      "file": "src/db.py",
      "line": 17,
      "lenses": ["logic", "security"],
      "summary": "sql concatenation",
      "evidence": "string concat with user input",
      "suggestion": "prepared statement"
    }
  ],
  "related": []
}
