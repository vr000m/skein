{
  "schema_version": 1,
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
      "category": "parser",
      "file": "src/[weird]{file}.py",
      "line": 42,
      "lenses": ["logic", "security"],
      "summary": "handles brackets [] and braces {} with slash \\ and quote \"",
      "evidence": "array [ marker ] object { marker } combo \\\" ] } [ { end",
      "suggestion": "preserve backslash \\ and quoted \" text"
    }
  ],
  "related": []
}
