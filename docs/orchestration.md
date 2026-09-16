# The orchestration model

What Swarm actually guarantees, what it costs, and where it breaks.

---

## 1. The claim

> No merge conflicts within a run. By construction, not by convention.

This is a real guarantee and it is worth being precise about its scope, because
the precision is what makes it useful.

The mechanism is exclusive file ownership. Before any code is written, the work
is partitioned so that no two concurrently-running tasks may write the same
file. Each task executes in its own git worktree, on its own branch. At the end,
the branches merge into one — and because their changed-file sets are disjoint,
git has nothing to reconcile.

The guarantee holds **within a run**, over **files**, for **text-level
conflicts**. It says nothing about whether the merged result compiles, and it
never claimed to. That distinction is the single most important thing to
understand about this design, and section 4 is about what falls into the gap.

The invariant is enforced three times, at increasing cost and decreasing
convenience:

| Where | When | Cost of catching it here |
|---|---|---|
| `lib/validate-spec.sh`, rule 8 | Authoring | Seconds. An error message. |
| Orchestrator, phase 1 step 5 | Before dispatch | One Architect call. |
| `hooks/pre-tool-use-scope-guard.sh` | Mid-flight | A stalled Drone and wasted tokens. |

Three layers for one invariant looks redundant. It is not. The first two operate
on declared intent, and an agent's declared intent and its actual writes are
different things. The hook is the only layer that observes what actually
happened, and it is the only one that cannot be reasoned around.

**The glob subtlety.** Both the validator and the hook treat `*` as bounded to a
single path segment; `**` is the only way to cross a directory. This matters more
than it sounds. Under bash's native globbing, `*` matches `/`, so a scope of
`src/api/*.ts` silently claims `src/api/v2/internal/handler.ts`. Two scopes that
a human reads as disjoint then overlap at runtime, and the guarantee evaporates
without anything appearing to go wrong. Both implementations were carrying this
bug; both now convert patterns to anchored regexes with segment-bounded
wildcards, and the behaviour is pinned by tests.

---

## 2. Why a spec, and not a prompt

The orchestrator can run in freeform mode: hand it prose, and an Opus-class
Architect reads the codebase and invents the partition. That works, and it is
the right entry point for small work.

It also puts the most consequential decision in the run — how to cut the
work — inside a single model call that nobody reviews. A structured spec moves
that decision to a human, in a file, in version control, before any money is
spent on implementation.

This is the same insight that made spec-driven development the fastest-growing
idea in agentic coding this year: GitHub's Spec Kit passed 115,000 stars within
four months of launch, and AWS built an IDE around the same premise. The
industry converged on it for a reason that applies with extra force here —
**with parallel agents, a bad decomposition does not just produce bad code, it
produces bad code that cannot be merged.** The cost of a vague spec scales with
the width of the swarm.

Concretely, a spec buys four things a prompt cannot:

- **The partition is reviewable before it is expensive.** You see the file
  ownership as a diff, in a pull request, and argue with it for free.
- **It is deterministic across runs.** The same spec produces the same waves.
  A prompt produces a different partition every time, which makes failures
  irreproducible.
- **It carries negative space.** `## Scope Boundaries` tells agents what not to
  touch. There is no natural place for that in a prompt, and it is the main
  defence against an agent helpfully refactoring the module next door.
- **It survives the run.** The spec is the artifact you review the PR against.

---

## 3. The spec as compiler input

The format is deliberately small, because every section exists to feed a
specific decision the orchestrator has to make. Nothing in it is documentation.

| Section | Who consumes it | What breaks without it |
|---|---|---|
| `## Outcome` | Reviewer, for coverage | No definition of done; review degenerates to "looks fine" |
| `## Scope Boundaries` | Architect, Drones | Agents drift into adjacent code |
| `## Constraints` | Drones, QA | Non-functional requirements silently dropped |
| `## Prior Decisions` / `## Root Cause` | Drones | Four agents independently relitigate settled architecture |
| `## Task Breakdown` | Orchestrator | No task graph; nothing to parallelise |
| `## Verification Criteria` | QA, Reviewer | Nothing gates the merge |

The compile step is mechanical. `(files: ...)` becomes `fileScope`; `(after: ...)`
becomes `dependsOn`; waves fall out of the dependency edges by topological
layering. In structured mode the orchestrator does this itself and never spends
an Opus call re-deriving a partition the author already wrote down.

**Two rules do the load-bearing work:**

*Rule 8 — no file in two tasks.* This is the concurrency primitive, decided at
authoring time where a human can see it, not negotiated at runtime.

*Rule 7 — at least one `[programmatic]` criterion.* Without it the QA phase has
nothing to run, and becomes one language model asking another whether the code
looks good. That is not a gate. It is theatre with a token bill.

**On criteria.** The `[programmatic]` / `[human]` split maps to who is gated.
Programmatic criteria gate the swarm; human criteria gate you. Both belong in
the spec — dropping the human ones does not make the judgement unnecessary, it
just makes it invisible.

For behavioural criteria, the schema pushes toward **EARS** — *When \<trigger\>,
the system shall \<response\>*. The reason is not formality for its own sake. A
requirement in that shape names a trigger and an observable response, which is
exactly the information a test case needs. The syntax that removes ambiguity for
a human is the syntax that makes "done" mechanically checkable for an agent. In
practice: write the criterion in EARS and you have specified the test.

One heuristic catches most bad criteria. Ask: *would this have passed before the
change?* If yes, it gates nothing.

---

## 4. Where this breaks

The honest part.

**Semantic conflicts are not merge conflicts.** Two agents with disjoint file
sets can still produce code that does not work together — T1 renames a field in
its module, T2 consumes the old name from its own. Git merges both cleanly. The
build fails. The file-ownership guarantee is precisely and only a guarantee
about text, and this is the failure mode it does not cover.

Four things mitigate it, none completely. `lib/check-integration.sh` now runs
before the merge, in phase 4: it diffs each task branch against the base,
extracts symbols the branch removed, and cross-references them against what
every other branch still calls, naming the symbol and both tasks on a hit. It
is a textual heuristic, not a type checker — it recognises a fixed set of
definition shapes per language and reports an unrecognised extension as a
coverage gap rather than guessing at it — so it catches the case named above
and nothing subtler than that. Past it: the Reviewer sees the combined diff and
is explicitly tasked with cross-task consistency, catching what the heuristic
cannot; the merged branch gets a full build and test run in phase 5, which is
the first moment the combination actually executes; and waves are sequenced, so
a task that depends on another's interface runs after it, against real code.
It remains the most likely way a run produces a broken branch, and you should
expect it rather than be surprised by it.

**Concurrent git operations corrupt shared metadata.** Worktrees of one
repository share `.git`. Running git commands across several of them at once
contends on that shared state, and the documented failure is index or ref
corruption — a category of bug that surfaces long after the run, in a repo you
now do not trust. Every git operation in phases 4 and 5 is therefore serialized,
and that is not a performance oversight to be optimised away later.

**The partition is guessed from a static read.** The Architect assigns ownership
by reading code before any of it changes. It cannot know that implementing T3
will turn out to require touching T1's file. When that happens the scope guard
blocks the write, and the Drone reports it rather than working around it — which
is the correct behaviour, but it means the run stalls on a decomposition error
discovered at the worst possible moment.

This is why the Architect is instructed to prefer fewer, larger tasks. The
instinct with a parallel system is to maximise width; the economics point the
other way. Every extra task carries its own context load, its own QA pass, and
its own chance of colliding. Three well-separated tasks routinely beat seven
that all need the same registration file.

**Refusal is a feature.** The Architect can return `{"refused": true}` when the
work genuinely does not partition. Forcing a swarm onto sequential work produces
conflicts, retries, and a worse result than one focused session. A refusal is the
system working. Relatedly, if the task graph comes back with one task per wave,
the orchestrator says so and recommends a single session — a swarm with no
parallelism is pure overhead.

**Cost is not obviously favourable.** A run spends an Opus decomposition, N
Sonnet implementations, N Sonnet QA passes, and a Sonnet review. Against one
session doing the work directly, the swarm wins on wall-clock when N is genuinely
independent and loses on tokens almost always. It is a latency optimisation
bought with money, and it is worth it when the work is wide and you are waiting.

---

## 5. Making it fit any software factory

The original was tuned to a single organisation: a hand-written domain map of
that company's business areas, a spec `domain` field constrained to an enum of
its internal systems, and a verification map that assumed one build toolchain. Every one of those made specs written
elsewhere invalid on arrival. Three changes generalise it.

**Replace the domain map with stack detection.** A hand-maintained domain map
encodes one organisation's business areas and rots the moment you point the
swarm at a different repo. What the orchestrator actually needs is narrower and
universal: how do I build this, how do I test it, how do I lint it.
`lib/detect-stack.sh` answers that for Node, .NET, Rust, Go, Python, Maven,
Gradle, Ruby, and Make, and reports which convention files the repo carries.

Critically, **it returns `null` rather than guessing**, and QA reports `SKIPPED`
rather than `PASS` for a check it could not run. A verification system that
silently degrades to no verification is worse than no verification system,
because you stop watching.

**Unconstrain the vocabulary.** `domain` became `area`, a free-form label. The
schema will not enforce one organisation's taxonomy on another's. Any team that
wants a controlled vocabulary can add a CI check; the schema stays portable.

**Keep the commands out of the schema.** Nothing in the spec format knows about
any toolchain. Concrete commands live in the `[programmatic]` criteria and come
from the detector or the operator. That separation is what lets one schema drive
a Rust service and a Django monolith.

The remaining extension points are deliberate: constrain `area` in CI if you
want a taxonomy; wrap the validator to require category-specific constraints by
`kind` if you are in a regulated environment; put bespoke build commands in
`~/.config/swarm/config.yaml`. What you should not do is add sections. Every
section the orchestrator does not read is a section that will drift, and a stale
spec is worse than a thin one.

---

## 6. How this sits against the field

Swarm occupies a specific niche and it is useful to know which one.

**GitHub Spec Kit** standardises the spec-to-plan-to-tasks pipeline across 29
agent integrations. It is broader, better supported, and agent-agnostic. It does
not orchestrate parallel execution or enforce file ownership — it produces the
plan and hands it to one agent.

**Kiro** wraps requirements, design, and tasks in an IDE, with EARS as the
requirement syntax. Strongest on the authoring side, and the reason this schema
leans on EARS. Single-agent execution.

**Worktree orchestrators** (Cursor's 2026.1 worktree support, and the various
scheduling layers around it) handle isolation, scheduling, and diff review. They
treat a worktree as the unit of isolation and manage many of them. They do not
partition the work — they run whatever you give them and let you deal with the
overlap afterwards.

What is distinctive here is the combination: **the spec is what prevents the
conflict.** File ownership is declared in the spec, validated before dispatch,
and enforced at the tool boundary. Other systems detect or predict conflicts;
this one makes them unrepresentable within a run. The cost is that the spec has
to be right, which is why so much of this design is about spec quality rather
than agent quality.

---

## 7. What is not built

Named honestly rather than left as a pleasant surprise.

- **Cost accounting.** Token reporting depends on what Claude Code exposes, so
  the run cannot be budgeted in advance.
- **Spec-to-code drift detection.** Once the branch merges, nothing notices when
  the code moves away from the spec that produced it.

Three gaps that used to sit in this list are addressed, with caveats worth
reading before you rely on them:

- **Cross-run isolation** is closed. `lib/run-lock.sh` takes a
  repository-scoped lock, acquired in orchestrator phase 0 before `.swarm/` is
  touched, and a second run against the same repo is refused by name rather
  than colliding silently. A lock left by a dead process is reclaimable, but
  only by explicit operator action — the orchestrator never reclaims one
  itself.
- **Wave-level resumption** is closed. `lib/resume-state.sh` records each task
  and each wave the instant it completes, and a fresh orchestrator process
  reads that state back, cross-checked against git, instead of restarting from
  phase 0. A wave recorded only partially complete is surfaced to the operator
  to decide, not resolved automatically.
- **Semantic conflict detection** is narrowed, not closed. `lib/check-integration.sh`
  runs before the merge and catches the specific failure mode described in
  section 4 — one branch removes or renames something another branch still
  calls — but it is a textual heuristic, not a type checker, and it reports an
  unrecognised language as a coverage gap rather than a pass. See section 4 for
  the full account of what still falls through.
