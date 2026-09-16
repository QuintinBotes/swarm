---
schema: swarm-spec
schema_version: "2.0"
spec_id: 2026-09-16_fixture
kind: feature
status: Draft
owner: test@example.com
area: testing
---

## Outcome

A fixture used to prove the validator rejects malformed specs.

## Scope Boundaries

- `elsewhere/` — not touched

## Constraints

- Must remain a fixture

## Prior Decisions

- Fixtures live under tests/

## Task Breakdown

- [ ] T1 First task (files: src/shared.ts, src/one.ts)
- [ ] T2 Second task (files: src/shared.ts)

## Verification Criteria

- `[programmatic]` `npm test` passes
