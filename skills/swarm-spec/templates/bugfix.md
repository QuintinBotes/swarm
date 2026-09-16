---
schema: swarm-spec
schema_version: "2.0"
spec_id: YYYY-MM-DD_short-kebab-name
kind: bugfix
status: Draft
owner: you@example.com
area: replace-me
---

## Outcome

<One paragraph describing correct behaviour once the fix ships. Describe the
fixed state, not the bug.>

## Scope Boundaries

- <adjacent code that is NOT being fixed in this spec>
- <the tempting refactor you are deliberately not doing>

## Constraints

- No behaviour change outside the described defect
- <compatibility requirement — existing data, existing callers>
- <performance requirement, if the fix touches a hot path>

## Root Cause

**Symptom:** <what users or operators observe>

**Reproduction:** <numbered, deterministic steps>

**Cause:** <the specific code or config that is wrong, and why it is wrong>

**References:** <issue id, error-tracker event, log excerpt>

## Task Breakdown

- [ ] T1 Add a failing test that reproduces the defect (files: tests/path/RegressionTest.ext)
- [ ] T2 <the fix> (files: src/path/File.ext)
- [ ] T3 <follow-on, if the fix needs data repair> (files: path/migration.ext) (after: T2)

## Verification Criteria

- `[programmatic]` The regression test in `tests/path/RegressionTest.ext` fails before T2 and passes after
- `[programmatic]` `<the full test command>` passes with no new failures
- `[human]` <confirmation that existing affected records behave correctly>
