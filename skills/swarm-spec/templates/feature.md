---
schema: swarm-spec
schema_version: "2.0"
spec_id: YYYY-MM-DD_short-kebab-name
kind: feature
status: Draft
owner: you@example.com
area: replace-me
---

## Outcome

<One paragraph. What is observably different once this ships, described from
outside the system. Someone who has never seen the code should be able to
confirm or deny it by using the product.>

## Scope Boundaries

- `path/that/is/not/touched/` — <why it is excluded>
- <a behaviour explicitly out of scope>

## Constraints

- <performance budget, stated as a number>
- <backwards-compatibility requirement>
- <data handling, privacy, or security requirement>
- <tenancy or isolation requirement, if the system is multi-tenant>

## Prior Decisions

- <decision already made, and where — an ADR, a thread, an earlier spec>
- <a rejected alternative and the reason, so the swarm does not revisit it>

## Task Breakdown

- [ ] T1 <task> (files: path/one.ext, path/two.ext)
- [ ] T2 <task> (files: path/three.ext)
- [ ] T3 <task> (files: path/four.ext) (after: T1, T2)

## Verification Criteria

- `[programmatic]` `<the build command>` succeeds
- `[programmatic]` `<the test command>` passes
- `[programmatic]` When <trigger>, the system shall <response> — covered by `<test name>`
- `[human]` <something needing judgement>
