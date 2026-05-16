{
  "schema_version": 2,
  "summary": {
    "raw": 1,
    "merged": 0,
    "unique": 1,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Minor",
      "category": "style",
      "file": "src/foo.py",
      "line": 7,
      "lenses": ["logic"],
      "summary": "typo",
      "evidence": "docstring says recieve",
      "suggestion": "fix spelling",
      "auto_fix": {"kind": "docstring_typo", "before": "recieve", "after": "receive", "scope": "file"}
    }
  ],
  "related": []
}
