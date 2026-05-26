# Toolchain: Python (pytest + mypy + ruff)

This file is injected into the fan-out agent prompt via `{{TOOLCHAIN_CONTEXT}}`.
It provides Python-specific setup, commands, and pitfalls.

---

## Environment Setup

Prefer package manager commands in this order:

```
if [[ -f uv.lock ]] || ([[ -f pyproject.toml ]] && grep -q "^\[tool\.uv\]" pyproject.toml); then
  uv sync --dev
elif [[ -f poetry.lock ]]; then
  poetry install --with dev
elif [[ -f requirements-dev.txt ]]; then
  python -m pip install -r requirements-dev.txt
elif [[ -f requirements.txt ]]; then
  python -m pip install -r requirements.txt
else
  # Fall back to project-specific docs
  echo "No standard Python dependency manifest found"
fi
```

Use the same tool runner for follow-up commands:
- `uv run ...` when using uv
- `poetry run ...` when using Poetry
- `python -m ...` when using pip/venv

## Test Commands

```
<runner> pytest -v
```

## Type Check Commands

```
<runner> mypy <paths-from-project-config>
```

If mypy paths are declared in `pyproject.toml`/`mypy.ini`, use those. Otherwise
default to code + test roots present in the repo.

## Lint Commands

```
<runner> ruff check <paths-from-project-config-or-dot>
```

## Known Pitfalls

These are real issues hit during foundation work. Avoid repeating them.

### Pydantic

- **Use `Model.model_validate(dict)` not `Model(**dict)` in tests.** Spreading a
  `dict[str, object]` with `**` into a Pydantic constructor fails mypy strict
  (`arg-type` error). Always construct from dicts via `model_validate()`.
- **Tuple fields lose their type on JSON round-trip.** JSON serializes tuples as
  lists. If a model has `tuple[int, int]` fields, add a `field_validator(mode="before")`
  that coerces lists back to tuples, and write a round-trip test proving it works.
- **Use `@computed_field` not `@property` for derived values.** Plain `@property`
  does not appear in `model_dump()` or JSON serialization. Use
  `@computed_field @property` so the value is included.
- **Validate model constraints explicitly.** If a docstring says "exactly one of X,
  Y, Z", add a `model_validator(mode="after")` that enforces it. Don't rely on
  documentation alone.

### mypy

- **Respect project strictness settings.** If strict mode is enabled, zero mypy
  errors are required before finishing.
- **Tests may have different mypy overrides.** Use project config to understand
  expected behavior and still treat reported errors as actionable.
- **Run mypy as part of your verification gate.** `pytest` passing is not enough.
  Code that passes all tests can still have type errors that break downstream consumers.

### Testing

- **Test config/settings models too**, not just domain types. Defaults, computed
  fields, serialization round-trips, and nested overrides all need coverage.
- **Test validation failures with `pytest.raises`.** If your model rejects invalid
  input, prove it with a test.
- **Check async test configuration before adding markers.** Follow the project's
  configured `pytest-asyncio` mode if present.

### Dependencies

- **Use tight version ranges** like `>=0.6,<1.0` not `>=0.5`. Check that the
  lower bound matches the API features you actually use.

## Result Template Additions

Include this under the existing `## Static Analysis` section in `.fan-out-result.md`:

```markdown
- mypy: [command(s), pass/fail, number of errors]
- ruff: [command(s), pass/fail, number of errors]
```
