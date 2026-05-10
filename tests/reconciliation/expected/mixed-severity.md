{
  "summary": {
    "raw": 2,
    "merged": 1,
    "unique": 1,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "correctness",
      "file": "src/foo.py",
      "line": 42,
      "lenses": ["logic", "security"],
      "summary": "unbounded loop",
      "evidence": "may overrun buffer",
      "suggestion": "bounds check"
    }
  ],
  "related": []
}
