# swarm-spec Schema Reference — v2.0

This is the canonical contract for the `swarm-spec` format. It is read by humans
authoring specs, by the `/spec` wizard, by `lib/validate-spec.sh`, and by the
Architect agent when it builds a task graph.

A swarm-spec is not a design document. It is **the input to an execution
engine**. Every section exists because the orchestrator needs it to make a
decision. If a section would not change what the swarm does, it does not belong
in the spec.

---

## 0. Design principles

Four rules explain every choice below.

**Specify the boundary, not the solution.** The spec says what must be true when
the work is done and which files may change to make it true. It does not
prescribe algorithms. Over-specified specs produce agents that transcribe rather
than engineer, and they rot the moment the codebase moves.

**Every claim must be checkable by a command.** A criterion an agent cannot run
is a criterion that does not gate anything. `[human]` criteria are permitted and
useful, but they gate the human review, not the swarm. At least one
`[programmatic]` criterion is mandatory.

**File ownership is the concurrency primitive.** Parallel agents are safe
because no two of them can write the same file, and that is decided at
authoring time, in the spec, where a human can see it. It is not negotiated at
runtime.

**The spec is stack-agnostic; the commands are not.** Nothing in this schema
knows about .NET, Node, or any particular repo. The concrete commands live in
the `[programmatic]` criteria and come from `lib/detect-stack.sh` or the
operator. That separation is what lets the same schema drive a Rust service and
a Django monolith.

---

## 1. Frontmatter

Every spec opens with a YAML frontmatter block delimited by `---`. Seven fields
are required; order within the block does not matter.

| Field | Type | Notes |
|---|---|---|
| `schema` | literal | Must be exactly `swarm-spec`. |
| `schema_version` | string | Semver major.minor. Current: `"2.0"`. Always quote it, or YAML reads it as a float. |
| `spec_id` | string | `<YYYY-MM-DD>_<kebab-name>`. The date is creation day; the name is under 40 characters. |
| `kind` | enum | `feature`, `bugfix`, `workflow`, or `refactor`. Selects the template and decides whether the spec needs `## Root Cause` or `## Prior Decisions`. |
| `status` | enum | `Draft` → `Approved` → `In Progress` → `Verified` → `Shipped`. Authors set `Draft`; the post-task hook advances it. |
| `owner` | string | Email or version-control username. The human accountable for the outcome, not the agent that writes the code. |
| `area` | string | A free-form label for the part of the system this touches — `billing`, `auth`, `ingest`. Used for routing and reporting only. |

`area` is deliberately unconstrained. An earlier version of this schema pinned
it to an enum of one company's business domains, which made every spec written
elsewhere invalid on arrival. Any organisation that wants a controlled
vocabulary can enforce one in CI; the schema will not do it for them.

```yaml
---
schema: swarm-spec
schema_version: "2.0"
spec_id: 2026-09-16_idempotent-webhook-delivery
kind: feature
status: Draft
owner: jane@example.com
area: integrations
---
```

---

## 2. Required sections

Sections use H2 headings and must appear in this order.

### `## Outcome`

One paragraph. What is observably different once this ships, stated from the
outside. No implementation detail.

The test for a good Outcome: could someone who has never seen the code confirm
or deny it by using the system?

> Webhook deliveries are idempotent. A consumer that receives the same event
> twice, because of a retry or a redelivery, processes it once. Duplicate
> deliveries are acknowledged with the original response and produce no
> additional side effects.

### `## Scope Boundaries`

A bullet list of what this spec will **not** touch, with a reason each.

This section does more work than it looks like it does. It is the main defence
against an agent that "helpfully" refactors an adjacent module, and it gives the
Architect explicit negative space when it assigns file ownership.

> - `src/consumers/` — consumer-side handling is a separate spec
> - `infra/terraform/` — no infrastructure changes; the existing queue is reused
> - Any change to the public webhook payload shape

### `## Constraints`

Hard requirements the implementation must satisfy. Each bullet should be
falsifiable. Cover whichever of these apply: performance budgets, backwards
compatibility, data handling and privacy, security and authorization, tenancy
isolation, operational limits, and dependency policy.

Write constraints as properties of the finished system, not as instructions.
"Use a Redis set" is an instruction and will be obeyed even when it is wrong.
"Deduplication state must survive a process restart" is a constraint and leaves
the engineering to the engineer.

> - Deduplication must hold for at least 24 hours and survive process restarts
> - No change to the `POST /webhooks` request or response contract
> - p99 added latency under 15 ms at 500 rps
> - Dedup keys must be scoped per tenant; one tenant must not be able to
>   suppress another's deliveries

### `## Prior Decisions` *or* `## Root Cause`

Exactly one, never both.

**`## Prior Decisions`** — for `feature`, `workflow`, and `refactor`. The
choices already made, and where they were made. This stops the swarm relitigating
settled architecture in four worktrees simultaneously.

**`## Root Cause`** — required for `kind: bugfix`. Four parts: symptom,
reproduction, cause, references. A bugfix spec without a confirmed cause is a
research task, and research tasks should not be handed to a parallel swarm.

### `## Task Breakdown`

A checkbox list. This section compiles directly into the task graph, so its
syntax is strict.

```markdown
- [ ] T1 Add delivery-attempt ledger table and repository (files: src/storage/DeliveryLedger.cs, src/storage/Migrations/0042_delivery_ledger.sql)
- [ ] T2 Add idempotency-key extraction from inbound events (files: src/webhooks/KeyExtractor.cs)
- [ ] T3 Wire dedup check into the delivery pipeline (files: src/webhooks/DeliveryPipeline.cs) (after: T1, T2)
- [ ] T4 Integration tests for duplicate delivery (files: tests/integration/WebhookIdempotencyTests.cs) (after: T3)
```

Rules:

- **`T<n>` identifier**, sequential and unique.
- **`(files: ...)`** is mandatory. Comma-separated paths relative to the repo
  root. Three forms are supported, and the scope guard enforces them literally:
  - an exact path — `src/webhooks/pipeline.ts`
  - a glob, where `*` and `?` stay inside one path segment and `**` is the only
    way to cross a directory — `src/webhooks/*.ts`, `src/webhooks/**/*.ts`
  - a trailing slash, claiming anything new under a directory — `src/webhooks/dedup/`

  Prefer exact paths. A glob is a claim on files that do not exist yet, and the
  wider it is, the more likely it silently overlaps another task.
- **No file may appear in two tasks.** This is the invariant that makes parallel
  execution safe. If two tasks genuinely need the same file, they are one task.
- **`(after: T1, T2)`** is optional and declares dependencies. Tasks with no
  `after` run in the first wave. The Architect derives waves from these edges;
  you do not number waves by hand.
- **One task is one reviewable unit.** "Add the model" and "add the model's
  tests" are the same task. A task that cannot be reviewed on its own was split
  too finely.

### `## Verification Criteria`

A bullet list. Every criterion carries exactly one tag.

- **`[programmatic]`** — an agent can run it and read a pass/fail from the exit
  code. Put the command in backticks. These gate the swarm.
- **`[human]`** — needs judgement. These gate your review, and the swarm reports
  them to you rather than deciding them.

At least one `[programmatic]` criterion is required. A spec with only `[human]`
criteria cannot gate anything automatically, and the QA phase degenerates into
an agent asking another agent whether the code looks nice.

Prefer the **EARS** shapes for behavioural criteria — *When \<trigger\>, the
system shall \<response\>* — because a requirement in that form is already a
test case. That is the whole trick: the syntax that removes ambiguity for a
human is the syntax that makes "done" mechanically checkable for an agent.

> - `[programmatic]` `npm test -- tests/integration/WebhookIdempotencyTests` passes
> - `[programmatic]` When the same event id is delivered twice, the ledger shows one row — covered by `DuplicateDelivery_WritesOneLedgerRow`
> - `[programmatic]` `npm run build` succeeds with no new warnings
> - `[human]` The ledger's retention job is safe to run against production volume

---

## 3. Optional section

### `## Audit Log`

Auto-populated by `hooks/post-task-spec-update.sh` as tasks complete. Do not
write to it by hand; edits are overwritten.

---

## 4. Validation rules

`lib/validate-spec.sh` enforces these. A spec failing any of them is rejected
before a single agent is spawned.

1. Frontmatter is present, opens the file, and closes with `---`.
2. All seven required fields present; `schema` is exactly `swarm-spec`.
3. `status` is a known lifecycle value.
4. `kind` is a known work type.
5. All required sections present, in order; exactly one of `## Prior Decisions`
   or `## Root Cause`; bugfix specs use `## Root Cause`.
6. Every task has a `T<n>` id, ids are unique, and every task has a non-empty
   `(files: ...)` annotation.
7. Every `(after: ...)` reference resolves to a task defined in this spec, and
   no task depends on itself. Every verification criterion is tagged, and at
   least one is `[programmatic]`.
8. **No file path is claimed by more than one task.**

Rule 8 is the one worth failing a build over. Every other rule catches sloppiness;
rule 8 catches the class of bug that only shows up after four agents have spent
twenty minutes each writing code that cannot be merged.

---

## 5. Adapting the schema to your factory

The schema is intentionally small. Three extension points cover most house
rules without forking it:

**Constrain `area`.** Add a CI check that `area` is in your organisation's list.
The schema stays portable; your repo gets the vocabulary.

**Add required constraints by `kind`.** A regulated environment might require
every `kind: feature` spec to carry a data-handling constraint. That is a wrapper
check around `validate-spec.sh`, not a schema change.

**Supply the commands.** `lib/detect-stack.sh` guesses build, test, and lint for
common ecosystems. If your factory has a bespoke build, write the real commands
into `~/.config/swarm/config.yaml` or into the `[programmatic]` criteria
directly. The orchestrator never assumes a toolchain.

What you should not do is add sections. Every section the swarm does not read is
a section that will drift, and a stale spec is worse than a thin one.
