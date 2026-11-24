# Cache entries live in JSON files

**Status**: superseded
**Date**: 2026-10-01
**Applies to**: src/cache/*, src/legacy/*
**Supersedes**: none
**Superseded by**: 20261101-cache-store.md
**Source plan**: docs/dev_plans/20261001-cache.md

## Decision
Write each cache entry to its own JSON file under `var/cache/`.

## Why
No database was available at the time.

## Alternatives rejected
SQLite, rejected for the extra dependency.

## Consequences
Concurrent writers can corrupt an entry.
