---
schema: swarm-spec
schema_version: "2.0"
spec_id: YYYY-MM-DD_short-kebab-name
kind: refactor
status: Draft
owner: you@example.com
area: replace-me
---

## Outcome

<One paragraph. Refactors change structure, not behaviour — so state the
structural property that is true afterwards, and state plainly that observable
behaviour is unchanged.>

## Scope Boundaries

- <call sites deliberately left on the old shape, and when they get migrated>
- Any behaviour change — this spec is behaviour-preserving by definition

## Constraints

- Public contracts unchanged: <name them>
- <performance must not regress beyond a stated margin>
- <the change must be revertible as a single unit, or land behind a flag>

## Prior Decisions

- <the target shape, and where it was agreed>
- <why this is being done now>

## Task Breakdown

- [ ] T1 <introduce the new shape alongside the old> (files: src/path/NewShape.ext)
- [ ] T2 <migrate call sites, batch one> (files: src/area-a/*.ext) (after: T1)
- [ ] T3 <migrate call sites, batch two> (files: src/area-b/*.ext) (after: T1)
- [ ] T4 <remove the old shape> (files: src/path/OldShape.ext) (after: T2, T3)

## Verification Criteria

- `[programmatic]` `<the full test command>` passes with no test modified — behaviour is unchanged
- `[programmatic]` `<the build command>` succeeds
- `[programmatic]` No reference to the old shape remains — `<grep or lint command>` returns nothing
- `[human]` The new shape reads better than the old one at the three hardest call sites
