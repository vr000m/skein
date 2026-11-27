# Cache entries live in one SQLite store

**Status**: active
**Date**: 2026-11-01
**Applies to**: src/cache/*
**Supersedes**: 20261001-cache-files.md
**Superseded by**: none
**Source plan**: docs/dev_plans/20261001-cache.md

## Decision
All cache reads and writes go through `src/cache/store.py`, backed by one SQLite database. No module writes cache entries to files directly.

## Why
Per-entry JSON files were corrupted by concurrent writers.

## Alternatives rejected
Per-entry JSON files, the superseded record.

## Consequences
New cache code imports `store` and never opens files under `var/cache/`.
