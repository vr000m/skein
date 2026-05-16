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
      "severity": "Important",
      "category": "correctness",
      "file": "src/legacy.py",
      "line": 12,
      "lenses": ["logic"],
      "summary": "legacy JSONL still parses",
      "evidence": "finding has no auto_fix block",
      "suggestion": "surface as advisory"
    }
  ],
  "related": []
}
