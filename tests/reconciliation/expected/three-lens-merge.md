{
  "schema_version": 1,
  "summary": {
    "raw": 3,
    "merged": 1,
    "unique": 1,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Important",
      "category": "coupling",
      "file": "src/svc.py",
      "line": 99,
      "lenses": ["architecture", "logic", "security"],
      "summary": "tight coupling",
      "evidence": "direct import of impl",
      "suggestion": "introduce interface"
    }
  ],
  "related": []
}
