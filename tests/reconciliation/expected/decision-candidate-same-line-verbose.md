{
  "schema_version": 2,
  "summary": {
    "raw": 3,
    "merged": 0,
    "unique": 3,
    "related": 1,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "Security",
      "file": "a.py",
      "line": 3,
      "lenses": [
        "security"
      ],
      "summary": "token logged",
      "evidence": "print(token)",
      "suggestion": "drop the print"
    },
    {
      "severity": "Important",
      "category": "Documentation",
      "file": "a.py",
      "line": 3,
      "lenses": [
        "documentation"
      ],
      "summary": "Excuse: comment defers the fix",
      "evidence": "# TODO later",
      "suggestion": "fix it now"
    },
    {
      "severity": "Minor",
      "category": "Documentation",
      "file": "a.py",
      "line": 3,
      "lenses": [
        "documentation"
      ],
      "summary": "Decision candidate: chose a 3-retry bound",
      "evidence": "# three retries",
      "suggestion": "record the decision"
    }
  ],
  "related": [
    {
      "file": "a.py",
      "line": 3,
      "categories": [
        "Documentation",
        "Security"
      ]
    }
  ]
}
