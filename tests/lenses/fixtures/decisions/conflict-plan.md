# Task: Faster cache index

## Objective

Speed up cache lookups with an index kept beside the entries.

## Implementation Checklist

### Phase 1: Index files

**Impl files:** `src/cache/{store,index}.py`

- Write each index entry to its own JSON file under `var/cache/index/`, opened directly from `src/cache/index.py`.

## Technical Specifications

### Files to Modify

- `src/cache/store.py`

### New Files to Create

- `src/cache/index.py`

### Architecture Decisions

- Decision: the index bypasses the SQLite store and writes JSON files directly, because file writes are simpler.
