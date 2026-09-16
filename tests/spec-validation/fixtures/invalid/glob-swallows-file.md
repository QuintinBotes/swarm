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

Two tasks whose scopes look different but claim the same file.

## Scope Boundaries

- `elsewhere/` — not touched

## Constraints

- Must remain a fixture

## Prior Decisions

- None

## Task Breakdown

- [ ] T1 Rework the API surface (files: src/api/*.ts)
- [ ] T2 Fix one route (files: src/api/routes.ts)

## Verification Criteria

- `[programmatic]` `npm test` passes
