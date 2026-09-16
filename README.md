# Swarm

> *"The Queen has spoken. The Swarm obeys."*

A Claude Code plugin that runs coding agents in parallel without merge
conflicts. You write a spec; the Queen carves it into exclusive territories;
Drones build them in isolated worktrees; the Overlord validates each one; the
Defiler reviews the combined result.

**No merge conflicts within a run — by construction, not by convention.**

---

## Install

```bash
claude plugin install swarm
```

Or from inside a session: `/plugin install swarm`

Requires `git`, `jq`, and `bash`. Everything is shell and markdown; there is
nothing to compile.

---

## Use

```bash
/spec                      # author a spec, guided
/spec "add dark mode"      # draft one from a description
/swarm .swarm/specs/my.md  # run it
/swarm-status              # watch it
```

You can hand `/swarm` a plain description instead of a spec. It works, and it is
the right entry point for small changes. For anything wide enough to be worth
parallelising, write the spec — the decomposition is the decision that matters,
and a spec puts it in front of you before it costs anything.

`/spec` does not just fill in a template. It drafts the spec, then grills you
until an agent could actually implement it — see below.

---

## The roster

| Bioform | Role | Model | Access |
|---|---|---|---|
| **Queen** | Architect — owns the task graph and the file partition; refuses work that cannot be split | Opus | read-only |
| **Drone** | Implementor — one task, one worktree, one branch | Sonnet | its own scope only |
| **Overlord** | QA and security — validates each Drone before it rejoins the swarm | Sonnet | read-only |
| **Defiler** | Reviewer — the last gate on the combined diff | Sonnet | read-only |
| **Changeling** | Interrogator — a fresh-context adversarial read of a finished spec; reports what a Drone would have to guess | Opus | read-only |
| **Cerebrate** | The coordinating session — dispatches, gates, reports | — | — |
| **Overmind** | You — issue the directive, approve the partition | — | — |

---

## How the guarantee works

Tasks are grouped into waves. Everything in a wave runs at once, because the
partition guarantees their file scopes are disjoint. Wave N+1 waits for wave N
to pass QA — a single failing task holds the line.

The invariant is checked three times:

1. **At authoring** — `lib/validate-spec.sh` rejects a spec where two tasks
   claim the same file, including where a glob in one silently swallows an exact
   path in another.
2. **Before dispatch** — the orchestrator re-checks the compiled graph.
3. **Mid-flight** — a PreToolUse hook blocks any write outside the running
   Drone's declared scope. This is the only layer that observes what an agent
   actually did rather than what it declared, and it fails closed.

Read [`docs/orchestration.md`](docs/orchestration.md) for the full model,
including a straight account of what this does **not** guarantee.

---

## Lifecycle gates

Four points in a run used to fail silently. Each now has an explicit gate.

**One run at a time.** Before touching `.swarm/`, the orchestrator takes a
repository-scoped lock (`lib/run-lock.sh`) resolved via `git rev-parse
--git-common-dir`, so it holds across every worktree of the repo, not just the
current checkout. A second `/swarm` against the same repo is refused, by name,
with the run id already holding it — never two runs silently sharing
`task-graph.json`. A lock left by a process that no longer exists is
reclaimable (`run-lock.sh reclaim`), but only by the operator, deliberately —
the orchestrator never reclaims one on its own.

**Resumable waves.** The orchestrator records each task the instant its Drone
finishes and each wave the instant it clears QA (`lib/resume-state.sh`) —
never buffered to the end of the run, because a mid-run death is exactly the
case this exists for. If the process dies in wave 3, the next `/swarm` on the
same spec sees which waves are QA-verified, offers to resume from the first
unfinished one, and — if a wave is only partially done — asks whether to reuse
the existing task branches or rebuild them, rather than guessing.

**A pre-merge integration check.** Before the merge, not after,
`lib/check-integration.sh` diffs every task branch against the base, extracts
the symbols each branch removed, and cross-references them against what every
other branch still calls. A collision names the symbol and both tasks and
blocks the merge until the operator decides. It is a textual heuristic, not a
type checker — it recognises a fixed set of definition shapes per language and
reports an unrecognised file extension as a coverage gap rather than a pass.
It narrows the semantic-conflict gap described in
[`docs/orchestration.md`](docs/orchestration.md); it does not close it — the
merge build is still the backstop.

**An independent read on the spec.** `/spec` used to grade its own draft with
only a mechanical scorer. Now, once the scorer says `ready`, it dispatches the
**Changeling** — a fresh-context agent that reads only the spec and the
scorer's output, tries to describe a compliant-but-wrong implementation, and
reports blocking ambiguities a Drone would otherwise have to guess. The session
that wrote the spec cannot grade it honestly; the Changeling has no memory of
the conversation that did.

---

## The spec

A swarm-spec is the input to an execution engine, not a design document. Every
section feeds a decision the orchestrator makes.

```markdown
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
## Scope Boundaries
## Constraints
## Prior Decisions        (or ## Root Cause, for a bugfix)

## Task Breakdown
- [ ] T1 Add the ledger (files: src/storage/ledger.ts)
- [ ] T2 Extract the key (files: src/webhooks/key.ts)
- [ ] T3 Wire it up      (files: src/webhooks/pipeline.ts) (after: T1, T2)

## Verification Criteria
- `[programmatic]` `npm test` passes
- `[programmatic]` When an event id arrives twice, the ledger shall hold one row — covered by `duplicate delivery writes one row`
- `[human]` The retention job is safe at production volume
```

`(files: ...)` becomes the file scope. `(after: ...)` becomes the dependency
edges, and the waves fall out of them. Two rules carry the weight: **no file
appears in two tasks**, and **at least one criterion must be machine-runnable**.

Full contract: [`skills/swarm-spec/schema.md`](skills/swarm-spec/schema.md).
Worked examples: [`skills/swarm-spec/examples/`](skills/swarm-spec/examples/).

---

## The spec builder grills you

The bar is not "the template is filled in". It is: **could a competent agent
implement this without being able to ask you anything?** That is the situation a
Drone is in, and `/spec` is built around getting there.

It drafts the whole spec first — people correct a concrete proposal far better
than they generate one from a blank page — then attacks its own draft:

```bash
$ bash lib/score-spec.sh .swarm/specs/my-spec.md
{
  "overall": "not-ready",
  "dimensions": { "outcome": "weak", "constraints": "weak", ... },
  "interrogate_next": ["outcome", "constraints"],
  "findings": [
    { "dimension": "outcome",
      "finding": "Hedge words with no committed meaning: performant user-friendly" },
    { "dimension": "constraints",
      "finding": "Written as an instruction rather than a property — it will be
                  obeyed even where it is wrong: - Use a Redis cache" }
  ]
}
```

The signals are mechanical, so a model cannot talk itself past them: a hedge word
is present or it is not; a performance constraint has a number or it does not; a
criterion names a command or it names prose.

The questions are not. The technique is **malicious compliance** — rather than
asking "can you be more specific?", show the user the wrong implementation their
spec permits:

> "As written, I could sort alphabetically by title and be fully compliant. I
> assume you mean relevance — but relevance to what? Term frequency, recency, the
> customer's own history? Those give visibly different results for the same query."

One dimension is attacked per round, ordered by blast radius, because a weak
Outcome makes the criteria weak by construction. It stops when every dimension
clears, when two rounds produce no improvement, or when you tell it to — and it
says which dimensions are still soft rather than burying it.

Protocol and question ladders:
[`skills/swarm-spec/interrogation.md`](skills/swarm-spec/interrogation.md).

**Two gates, different questions.** `validate-spec.sh` checks form — sections
present, tasks annotated, no file claimed twice. `score-spec.sh` checks
readiness — whether the spec says anything at all. A spec can be `VALID` and
empty of meaning.

---

## Stack-agnostic by design

Nothing here knows about your toolchain. `lib/detect-stack.sh` works out the
build, test, and lint commands for Node, .NET, Rust, Go, Python, Maven, Gradle,
Ruby, and Make, and lists the convention files your repo carries.

When it cannot tell, it returns `null` and the orchestrator asks you. QA reports
`SKIPPED`, never `PASS`, for a check it could not run — a verification system
that silently degrades to no verification is worse than none, because you stop
watching it.

---

## Configuration

Optional, at `~/.config/swarm/config.yaml`:

```yaml
parallel_agents: 4        # cap on concurrent Drones per wave
default_model: sonnet
qa_enabled: true
reviewer_enabled: true
merge_strategy: serialized
```

`merge_strategy` stays `serialized` unless you have a reason. Concurrent git
commands across worktrees of one repository contend on shared `.git` metadata
and can corrupt it.

---

## The Creep

```
.swarm/
├── specs/            ← your specs
├── task-graph.json   ← the Queen's battle plan
├── current-task-id   ← which Drone this worktree belongs to
├── qa-status/        ← the Overlord's surveillance feed
└── resume/           ← wave/task completion, so a dead run can pick back up
```

The run lock lives outside this tree, at `<git-common-dir>/.swarm/lock` —
shared across every worktree of the repository, because two worktrees of one
repo must never run a swarm at the same time.

---

## Layout

```
agents/       Queen, Drone, Overlord, Defiler, Changeling
commands/     /swarm, /swarm-status, /spec
hooks/        scope guard, QA signal, stop gate
lib/          stack detection, spec detection, validation, readiness scoring,
              config, run locking, resume state, cross-task integration checking
skills/
  orchestrator/ the orchestrator
  swarm-spec/   the spec builder: schema, interrogation protocol, wizard,
                templates, examples
tests/        run with bash tests/run-all.sh
docs/         the orchestration model, in full
```

---

## Tests

```bash
bash tests/run-all.sh
```

198 tests across nine suites. They exercise the real scripts against real
temporary repositories and, where relevant, real git branches — the scope
guard against real hook payloads, the validator against specs that must be
rejected, the scorer against specs broken one dimension at a time, the
detector against generated projects in each ecosystem, the agent frontmatter
against the model-alias rule, the lock against concurrent acquire/release/
reclaim, resume state against partial and inconsistent waves, the integration
check against branches with real symbol collisions, and every script's own
bash 3.2 portability.

---

## Status

v0.4.0. Extracted from a private monorepo and generalised. Of the gaps
`docs/orchestration.md` named as open, cross-run isolation and wave-level
resumption are now closed and semantic conflict detection is narrowed but not
closed — see [Lifecycle gates](#lifecycle-gates) above, and section 7 of that
document for what is still genuinely open.

---

*"Evolution is the key to survival. Those who do not evolve are consumed."*
