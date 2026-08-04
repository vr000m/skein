{
  "schema_version": 2,
  "summary": {
    "raw": 6,
    "merged": 1,
    "unique": 4,
    "related": 1,
    "dropped": 0
  },
  "findings": [
    {
      "severity": "Critical",
      "category": "Assumption",
      "file": "docs/dev_plans/example-plan.md",
      "line": 42,
      "lenses": ["architecture", "sequencing"],
      "summary": "Architecture Decisions assumes an async queue",
      "evidence": "plan line 42 references a shared async queue",
      "suggestion": "adopt an async queue for cross-worker communication"
    },
    {
      "severity": "Critical",
      "category": "Contradiction",
      "file": "docs/dev_plans/example-plan.md",
      "line": 42,
      "lenses": ["contradiction"],
      "summary": "Architecture Decisions assumes an async queue while Requirements commits to synchronous processing",
      "evidence": "plan line 42 (Architecture Decisions: async queue) vs plan line 42 (Requirements: synchronous processing)",
      "suggestion": "pick one processing model and align both sections"
    },
    {
      "severity": "Important",
      "category": "Contradiction",
      "file": "",
      "line": -1,
      "lenses": ["contradiction"],
      "summary": "Two lenses propose mutually exclusive fixes with no shared plan-line anchor",
      "evidence": "architecture lens suggestion vs sequencing lens suggestion, no common plan line to anchor on",
      "suggestion": "resolve which lens's fix takes precedence"
    },
    {
      "severity": "Minor",
      "category": "Contradiction",
      "file": "",
      "line": -1,
      "lenses": ["contradiction"],
      "summary": "A second, unrelated plan-internal contradiction with no shared anchor",
      "evidence": "plan section A vs plan section B, no shared plan line",
      "suggestion": "reconcile the two sections' wording"
    },
    {
      "severity": "Minor",
      "category": "Nonexistent Reference",
      "file": "scripts/nonexistent-script.sh",
      "line": 10,
      "lenses": ["codebase-claims"],
      "summary": "plan references a script that does not exist",
      "evidence": "scripts/nonexistent-script.sh not found in repo",
      "suggestion": "verify and update plan reference"
    }
  ],
  "related": [
    {
      "file": "docs/dev_plans/example-plan.md",
      "line": 42,
      "categories": ["Assumption", "Contradiction"]
    }
  ]
}
