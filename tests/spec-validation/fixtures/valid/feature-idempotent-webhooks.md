---
schema: swarm-spec
schema_version: "2.0"
spec_id: 2026-09-16_idempotent-webhook-delivery
kind: feature
status: Draft
owner: jane@example.com
area: integrations
---

## Outcome

Webhook deliveries are idempotent. When the same event is delivered more than
once — because of a network retry, a redelivery request, or an at-least-once
queue — the receiving pipeline processes it exactly once. Duplicate deliveries
return the original response and produce no additional side effects. Operators
can see, per event id, how many delivery attempts were made and which one won.

## Scope Boundaries

- `src/consumers/` — consumer-side deduplication is a separate spec
- `infra/` — no infrastructure changes; the existing queue and database are reused
- The public `POST /webhooks` request and response shapes — unchanged
- Historical events already delivered before this ships — no backfill

## Constraints

- Deduplication must hold for at least 24 hours and survive a process restart
- Dedup state must be scoped per tenant; one tenant must not be able to suppress
  another tenant's deliveries
- Added p99 latency must stay under 15 ms at 500 requests per second
- No change to the `POST /webhooks` contract — existing senders keep working
- Event payloads must not be written to logs; only event ids and tenant ids

## Prior Decisions

- Dedup state lives in the primary database rather than the cache, because the
  24-hour durability requirement rules out an eviction-based store (ADR-017)
- The idempotency key is the sender-supplied `event_id` when present, and a
  content hash otherwise — decided after the 2026-08 redelivery incident
- Rejected: deduplicating at the queue level. The queue is shared with three
  other pipelines and the change would not be isolatable.

## Task Breakdown

- [ ] T1 Add the delivery-ledger table and repository (files: src/storage/deliveryLedger.ts, src/storage/migrations/0042_delivery_ledger.sql)
- [ ] T2 Extract the idempotency key from inbound events, with a content-hash fallback (files: src/webhooks/idempotencyKey.ts)
- [ ] T3 Wire the dedup check into the delivery pipeline (files: src/webhooks/deliveryPipeline.ts) (after: T1, T2)
- [ ] T4 Expose per-event attempt counts on the operator endpoint (files: src/api/operatorRoutes.ts) (after: T1)
- [ ] T5 Integration tests covering duplicate, concurrent, and expired-window delivery (files: tests/integration/webhookIdempotency.test.ts) (after: T3)

## Verification Criteria

- `[programmatic]` `npm run build` succeeds with no new TypeScript errors
- `[programmatic]` `npm test` passes
- `[programmatic]` When the same event id is delivered twice, the ledger shall contain exactly one completed row — covered by `duplicate delivery writes one ledger row`
- `[programmatic]` When two deliveries of the same event id race, exactly one shall perform side effects — covered by `concurrent duplicate delivery is serialized`
- `[programmatic]` When an event id is redelivered after 24 hours, the system shall process it as new — covered by `expired dedup window reprocesses`
- `[programmatic]` Event payload bodies do not appear in logs — `npm run test:log-redaction` passes
- `[human]` The ledger retention job is safe to run against production table volume
- `[human]` The operator endpoint's attempt view is legible during an active incident
