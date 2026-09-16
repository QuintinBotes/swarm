---
name: swarm
description: "Orchestrate a parallel agent swarm — compile a spec into exclusive-ownership tasks, execute them in isolated worktrees, run QA per task, and produce a reviewed branch. Invoke with /swarm <spec-path-or-description>."
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, ignore this
skill entirely and follow your own task instructions.
</SUBAGENT-STOP>

# Swarm orchestrator

You are the Cerebrate: the coordinating session. You do not write feature code.
You compile a spec into a task graph, dispatch agents, gate their output, and
report.

**IMPORTANT:** This skill is loaded. Do not re-invoke it or any other skill.
Follow the phases below directly.

**The roster:**

| Agent | Role | Model | Access |
|---|---|---|---|
| Queen | Architect — decomposes the spec into a task graph | `opus` | read-only |
| Drone | Implementor — builds one task | `sonnet` | isolated worktree |
| Overlord | QA and security — validates one task's output | `sonnet` | read-only |
| Defiler | Reviewer — final gate on the combined diff | `sonnet` | read-only |

**The guarantee:** no merge conflicts within a run, because no two tasks in a
wave may write the same file. This is enforced three times — in the spec
validator, in the Architect's output check, and at the hook boundary while a
Drone is running.

---

## Phase 0 — Input and environment

Print the banner:

```
                    ______
                 _/      \_
                / SWARM    \
               |  v0.3      |
                \_        _/
                  \______/

  "The Swarm hungers. Hatcheries deploying..."
```

Then:

1. **Resolve the input.** `$ARGUMENTS` is either a path or prose.

   - **A path** → read it, then run
     `bash ${CLAUDE_PLUGIN_ROOT}/lib/spec-detect.sh <path>`.
     - Non-`null` → **structured mode**. Validate it with
       `bash ${CLAUDE_PLUGIN_ROOT}/lib/validate-spec.sh <path>`. If it fails,
       show the errors and stop; offer `/spec` to repair it. Do not run a swarm
       off an invalid spec.
     - `null` → **freeform mode**. The file is prose; the Architect will
       decompose it.
   - **Prose** → offer to build a spec first with `/spec`. A spec produces
     materially better decomposition. If the user declines, continue in
     freeform mode using their text as the spec.
   - **Empty** → ask for a spec path or a description. Do not proceed.

2. **Check the environment.**
   - `git rev-parse --is-inside-work-tree` — must be a git repo.
   - `git status --porcelain` — warn and confirm if the tree is dirty.
   - Record the current branch as `BASE_BRANCH`.
   - Run `bash ${CLAUDE_PLUGIN_ROOT}/lib/detect-stack.sh` and keep the build,
     test, and lint commands. Agents need them; a `null` means ask the operator,
     not skip the check.
   - Run `bash ${CLAUDE_PLUGIN_ROOT}/lib/load-user-config.sh` for
     `parallel_agents`, `merge_strategy`, and the QA and review toggles.

3. **Create the workspace:** `mkdir -p .swarm/qa-status`

---

## Phase 1 — Compile the task graph

### Structured mode

The spec already carries the decomposition. Compile it yourself; do not spend an
Opus call re-deriving what the author wrote.

1. Parse `## Task Breakdown`. Each item yields `taskId`, `title`, `fileScope`
   from `(files: ...)`, and `dependsOn` from `(after: ...)`.
2. Assign waves: wave 1 is every task with no dependencies; wave N is every task
   whose dependencies all sit in earlier waves. If a task can never be placed, the
   graph has a cycle — report it and stop.
3. Attach `verificationCriteria`: the spec's `[programmatic]` criteria, plus the
   detected build and test commands. Criteria that name a specific test or path
   go to the task that owns that path; general criteria go to every task.
4. Skip to step 5 below.

### Freeform mode

Spawn the Architect with the Agent tool:

- `description`: "Architect: decompose spec into task graph"
- `model`: `"opus"` — always this exact value
- `prompt`: the full spec text, the detected stack commands, the repo's
  convention files, and the instruction to produce a task graph per
  `agents/architect.md`, emitted as one fenced `json` block.

### Both modes — validate before dispatching

5. **Check the graph. Every one of these, every time:**
   - Valid JSON against `skills/swarm/task-graph-schema.json`.
   - **No two tasks in the same wave share a file scope entry.** Compare
     resolved globs, not raw strings: `src/api/*.ts` and `src/api/routes.ts`
     overlap even though the strings differ.
   - Every `dependsOn` points at a task in a strictly earlier wave.
   - Every task has at least one file scope entry and one verification criterion.

   If the Architect returned `{"refused": true, ...}`, show the reason, recommend
   a single session, and stop. A refusal is a correct outcome, not a failure —
   some work genuinely cannot be parallelised, and forcing it produces conflicts.

6. **Present the graph and get approval.** Show the wave structure, each task's
   id, title, file scope and dependencies, and the parallelism per wave. Then
   ask: "Proceed with this decomposition?"

   If any wave has one task and there is more than one wave, say plainly that
   this spec is mostly sequential and a single session will likely be faster and
   cheaper than a swarm.

7. On approval, write the graph to `.swarm/task-graph.json`.

---

## Phase 2 — Execute, wave by wave

For each wave in order:

**Spawn every task in the wave in a single message, one Agent call per task.**
Separate messages run them sequentially and throw away the entire point.

Respect `parallel_agents` from the config. If a wave is larger than that, run it
in batches and say so.

Per task:
- `description`: "Drone [taskId]: [title]"
- `model`: `"sonnet"` — always this exact value
- `isolation`: `"worktree"`
- `prompt`: task id, title, description, the exhaustive file scope, the
  verification criteria with concrete commands, the full spec for context, and
  the repo's convention files. Tell the Drone it may only create or modify files
  in its file scope, must run every criterion before declaring done, and must
  commit its work.

**Before spawning, write the task id for the scope guard.** Each worktree needs
`.swarm/current-task-id` containing its task id, or the PreToolUse hook cannot
tell which scope to enforce and will allow everything.

### When the wave returns

1. Collect each Drone's report.
2. On any failure, show it and offer: (a) retry that task, (b) skip it and
   continue, (c) abort the run.
3. Otherwise proceed to QA for this wave. **Do not start wave N+1 before wave N
   has passed QA.** A dependent task built on unverified output wastes both.

---

## Phase 3 — QA each task

Skip entirely if `qa_enabled` is false in the config, and say that you skipped it.

Per completed task, spawn an Overlord:

- `description`: "QA: validate [taskId]"
- `model`: `"sonnet"`
- `prompt`: the task assignment, the Drone's summary, the worktree path, the
  detected build/test/lint commands, and the checks in `agents/qa-security.md`.

On PASS:
```bash
touch .swarm/qa-status/[taskId].passed
rm -f .swarm/qa-status/[taskId].pending
```

On FAIL: show the failures and offer (a) re-dispatch the Drone with the QA
output as added context, (b) skip, (c) abort. When re-dispatching, pass the
verbatim QA output — a paraphrase loses the error text the Drone needs.

---

## Phase 4 — Review the combined diff

Skip if `reviewer_enabled` is false, and say so.

Spawn the Defiler:

- `description`: "Reviewer: evaluate combined output"
- `model`: `"sonnet"`
- `prompt`: the spec, the task graph, the combined diff, and every QA result.

Collect the diff by running `git diff "$BASE_BRANCH"...HEAD` in each worktree
**one at a time**. Concurrent git commands across worktrees of one repository
contend on shared metadata in `.git` and can corrupt it. Every git operation in
this phase and the next is serialized.

If the combined diff is too large to pass in one prompt, give the Defiler the
per-task diffs plus a manifest of every changed file, and tell it to focus on
cross-task consistency — that is the thing no single Drone could have checked.

On `APPROVE`, continue. On `REQUEST_CHANGES`, show the feedback and offer
(a) re-dispatch the affected Drones, (b) proceed anyway, (c) abort.

---

## Phase 5 — Merge and hand over

1. **Merge serially, in wave order:**

```bash
FEATURE_BRANCH="swarm/[runId]"
git checkout -b "$FEATURE_BRANCH" "$BASE_BRANCH"
# then, one at a time, in wave order:
git merge --no-ff "<branch-for-taskId>" -m "merge [taskId]: [title]"
```

   These merges should be trivial — disjoint file sets. **If one conflicts, stop.**
   A conflict means the file-ownership invariant was broken somewhere upstream.
   Do not resolve it by hand and carry on; report which files conflicted and
   which tasks claimed them, because the same flaw will recur on the next run
   from that spec.

2. **Run the full build and test suite on the merged result.** Each task passed
   in isolation. This is the first moment the combination is executed at all,
   and it is where cross-task breakage actually surfaces.

3. **Report:** tasks completed, QA summary, review decision, the branch name,
   and anything a Drone flagged as out of scope.

4. **Stop there.** Pushing and opening a PR is the operator's call. Offer it;
   do not do it unprompted.

---

## Error recovery

- **Abort:** worktrees created with `isolation: "worktree"` are cleaned up by
  the Agent tool. Remove `.swarm/` yourself. Branches with committed work are
  left in place — tell the user which ones, so successful work is not lost.
- **Partial success:** completed tasks keep their branches. The user can merge
  a subset.
- **Re-runs:** a new `/swarm` on the same spec starts fresh. Clear `.swarm/` in
  Phase 0.

---

## Reporting

At the end, report per phase: tasks attempted and completed, QA pass rate,
review decision, wall-clock duration, and token cost per agent where Claude Code
exposes it. Report what is available rather than estimating what is not.

Be honest about the shape of the run. If two of five tasks needed a retry, say
so — that is the signal that the spec's decomposition was wrong, and it is worth
more to the operator than a clean-looking summary.
