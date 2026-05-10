{
  "summary": {
    "raw": 2,
    "merged": 0,
    "unique": 2,
    "related": 0,
    "dropped": 1
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "correctness",
      "file": "src/x.py",
      "line": 7,
      "lenses": ["logic"],
      "summary": "divide by zero",
      "evidence": "denominator unchecked",
      "suggestion": "guard with if"
    },
    {
      "severity": "Important",
      "category": "input",
      "file": "src/x.py",
      "line": 15,
      "lenses": ["security"],
      "summary": "unvalidated arg",
      "evidence": "raw query string used",
      "suggestion": "validate"
    }
  ],
  "related": []
}
