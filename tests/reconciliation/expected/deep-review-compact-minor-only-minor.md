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
      "category": "docs",
      "file": "src/util.py",
      "line": 55,
      "lenses": ["docs"],
      "summary": "missing docstring",
      "evidence": "public function has no docstring",
      "suggestion": "add docstring"
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
  "related": []
}
