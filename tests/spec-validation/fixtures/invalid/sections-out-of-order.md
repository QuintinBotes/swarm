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

Out of order on purpose.

## Constraints

- Must remain a fixture

## Scope Boundaries

- `elsewhere/` — not touched

## Prior Decisions

- None

## Task Breakdown

- [ ] T1 A task (files: src/one.ts)

## Verification Criteria

- `[programmatic]` `npm test` passes
