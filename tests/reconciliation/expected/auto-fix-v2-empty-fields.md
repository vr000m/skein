{
  "schema_version": 2,
  "summary": {
    "raw": 3,
    "merged": 0,
    "unique": 3,
    "related": 0,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "logic",
      "file": "src/a.py",
      "line": 1,
      "lenses": ["logic"],
      "summary": "would_apply with empty evidence + suggestion",
      "evidence": "",
      "suggestion": "",
      "auto_fix": {"kind": "unused_import", "before": "from os import path\n", "after": "", "scope": "file"},
      "auto_fix_status": "would_apply"
    },
    {
      "severity": "Important",
      "category": "naming",
      "file": "src/b.py",
      "line": 2,
      "lenses": ["logic"],
      "summary": "would_apply with empty suggestion only",
      "evidence": "documented evidence",
      "suggestion": "",
      "auto_fix": {"kind": "mechanical_replace", "before": "a", "after": "b", "scope": "file"},
      "auto_fix_status": "would_apply"
    },
    {
      "severity": "Minor",
      "category": "style",
      "file": "src/c.py",
      "line": 3,
      "lenses": ["logic"],
      "summary": "would_apply with empty evidence only",
      "evidence": "",
      "suggestion": "documented suggestion",
      "auto_fix": {"kind": "docstring_typo", "before": "x", "after": "y", "scope": "file"},
      "auto_fix_status": "would_apply"
    }
  ],
  "related": []
}
