---
name: swarm-spec
description: "Author, validate, and maintain swarm-spec files — the executable specification format the swarm consumes. Trigger when the user runs /spec, asks to write or fix a spec, opens a file matching .swarm/specs/*.md or SPEC_*.md, or is about to run /swarm without a spec in hand."
---

# swarm-spec — the spec builder

A swarm-spec is the input to an execution engine, not a design document. It
declares what must be true when the work is done, which files may change, and
which commands prove it. The orchestrator compiles it into a task graph; the
scope guard enforces its file annotations; the QA phase runs its criteria.

**The bar is not "the template is filled in". It is: could a competent agent
implement this correctly without being able to ask the author anything?** That is
the situation a Drone is in, and most of this skill exists to get a spec there.

| File | What it is for |
|---|---|
| `schema.md` | The format contract — sections, rules, what the validator enforces |
| `interrogation.md` | The adversarial questioning protocol — how to grill a spec until it is implementable |
| `wizard.md` | The guided end-to-end flow: gather, draft, interrogate, validate |
| `templates/`, `examples/` | Starting points. Always start from an example. |

Two scripts back this up, and they answer different questions:

- `lib/validate-spec.sh` — **form**. Are the sections present, is every task
  annotated, does any file appear twice? Pass or fail.
- `lib/score-spec.sh` — **readiness**. Does the spec actually say anything? Per
  dimension, with the specific evidence behind each verdict and an ordered list
  of what to attack next.

A spec can be `VALID` and say nothing at all. Both gates must clear.

## When to use this skill

- The user runs `/spec` (author or repair a spec)
- The user is about to run `/swarm` with only a sentence of intent — a spec
  produces materially better decomposition than prose
- The user opens a file under `.swarm/specs/` or named `SPEC_*.md`
- A spec fails `lib/validate-spec.sh` and needs fixing

## Authoring procedure

**Never start from a blank template.** Start from the closest example in
`examples/`, then replace its content. Blank templates produce specs that
satisfy the validator and tell the swarm nothing.

1. **Establish the stack before asking anything.** Run
   `bash ${CLAUDE_PLUGIN_ROOT}/lib/detect-stack.sh` in the target repo. The
   build, test, and lint commands it returns become the concrete commands in
   the `[programmatic]` criteria. If a field comes back `null`, ask the operator
   for that command — never invent one and never quietly drop the check.

2. **Read the repo's own conventions.** The detector lists them under
   `conventions` (CLAUDE.md, AGENTS.md, .claude/rules/, .editorconfig). File
   paths in the Task Breakdown must match how this repo is actually organised.

3. **Draft first, interview second.** Write the whole spec from what they gave
   you, then show it and let them correct it. People correct a concrete proposal
   far better than they generate one from a blank page. Running a wizard at
   someone who has just handed you three paragraphs of requirements is the
   fastest way to make them stop using this.

4. **Decompose against the real file tree.** Before writing the Task Breakdown,
   Glob the directories involved and read enough code to know which files a
   change actually touches. A Task Breakdown invented from the spec text alone
   will violate rule 8 the first time two tasks both need the same registration
   file.

5. **Interrogate until it is ready.** Score the draft with
   `bash ${CLAUDE_PLUGIN_ROOT}/lib/score-spec.sh <path>`, take the first entry in
   `interrogate_next`, and ask two or three focused questions about that
   dimension only. Fold the answers in, re-score, repeat. Follow
   `interrogation.md` — it has the technique and the question ladders.

   Stop when `overall` is `ready`, when two rounds in a row produce no
   improvement, or when the user says stop. Do not stop merely because the
   validator passes.

6. **Validate the form.** `bash ${CLAUDE_PLUGIN_ROOT}/lib/validate-spec.sh <path>`.
   Fix every error; address warnings or say why not.

7. **Save to `.swarm/specs/<spec_id>.md`** unless the user names another path. If
   any dimension is still below bar, say which, in one line, in the handover.

## Repairing a spec

When validation fails, fix the cause rather than the symptom.

- **Rule 8, shared file scope** — the usual fix is to merge the two tasks, not
  to split the file. Two tasks that need the same file are usually one unit of
  work that was cut in the wrong place. Splitting the file to satisfy the
  validator is how you get a spurious abstraction.
- **Rule 7, no programmatic criterion** — this almost always means the Outcome
  is vague. Go back and sharpen the Outcome; the criteria follow from it.
- **Rule 5, bugfix without a root cause** — do not invent one. Tell the user
  the cause is not established yet and that the work is an investigation, which
  should not be handed to a parallel swarm.

## Quality bar

The scorer catches mechanical weakness — hedge words, unquantified constraints,
criteria that name no command. These are the things neither script can check, and
they are what separate a spec that works from one that merely passes:

- **The Outcome is falsifiable from outside.** If confirming it requires reading
  the diff, rewrite it.
- **Constraints are properties, not instructions.** "Use a queue" is an
  instruction and will be obeyed even when wrong. "Must survive a restart" is a
  constraint and leaves the engineering open.
- **Every task is independently reviewable.** If a reviewer would have to open
  two tasks to judge either, they are one task.
- **Scope Boundaries name the tempting adjacent work.** The section earns its
  place by listing what a competent agent would otherwise drift into.
- **Criteria discriminate.** A criterion that passes both before and after the
  change gates nothing. Prefer EARS shapes — *When \<trigger\>, the system shall
  \<response\>* — because they name a trigger and an observable response, which
  is what a test needs.
