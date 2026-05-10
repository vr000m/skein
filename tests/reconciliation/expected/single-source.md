{
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
      "file": "src/foo.py",
      "line": 42,
      "lenses": ["logic"],
      "summary": "off-by-one",
      "evidence": "loop runs N+1 times",
      "suggestion": "use range(N)"
    }
  ],
  "related": []
}
