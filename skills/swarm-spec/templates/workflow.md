---
schema: swarm-spec
schema_version: "2.0"
spec_id: YYYY-MM-DD_short-kebab-name
kind: workflow
status: Draft
owner: you@example.com
area: replace-me
---

## Outcome

<One paragraph. What runs, when, and what exists afterwards that did not before.>

## Scope Boundaries

- <systems the job reads but never writes>
- <alerting or dashboards not included in this spec>

## Constraints

- **Trigger:** <cron expression, event, or manual>
- **Idempotency:** <what happens when the job runs twice on the same input>
- **Failure handling:** <retries, backoff, dead-letter, and who is paged>
- **Runtime budget:** <maximum duration and resource ceiling>
- **Data handling:** <retention, residency, and what must never be logged>

## Prior Decisions

- <chosen scheduler or runtime, and why>
- <rejected alternative and the reason>

## Task Breakdown

- [ ] T1 <job definition and schedule> (files: path/job.ext)
- [ ] T2 <core processing logic> (files: src/path/Processor.ext)
- [ ] T3 <observability: metrics, structured logs> (files: src/path/Telemetry.ext) (after: T2)
- [ ] T4 <tests, including the replay-twice case> (files: tests/path/JobTests.ext) (after: T2)

## Verification Criteria

- `[programmatic]` `<the test command>` passes
- `[programmatic]` Running the job twice over identical input produces one set of results — covered by `<test name>`
- `[programmatic]` When the downstream dependency is unavailable, the job shall retry and then dead-letter — covered by `<test name>`
- `[human]` The job's failure alert reaches the right on-call rotation
