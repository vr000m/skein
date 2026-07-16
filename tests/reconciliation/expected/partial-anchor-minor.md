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
      "category": "Style",
      "file": "src/foo.py",
      "line": null,
      "lenses": ["logic"],
      "summary": "file set, line missing",
      "evidence": "file present but no line number",
      "suggestion": "n/a"
    },
    {
      "severity": "Minor",
      "category": "Style",
      "file": "",
      "line": 42,
      "lenses": ["logic"],
      "summary": "file missing, line set",
      "evidence": "line present but no file",
      "suggestion": "n/a"
    }
  ],
  "related": []
}
