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
      "category": "style",
      "file": "src/util.py",
      "line": 10,
      "lenses": ["logic"],
      "summary": "unused import",
      "evidence": "import os never used",
      "suggestion": "remove import"
    },
    {
      "severity": "Minor",
      "category": "style",
      "file": "src/util.py",
      "line": 55,
      "lenses": ["logic"],
      "summary": "long line",
      "evidence": "line exceeds 120 chars",
      "suggestion": "wrap"
    }
  ],
  "related": []
}
