---
name: swarm-spec/wizard
description: "Guided flow for authoring a swarm-spec: gather, draft, interrogate until ready, validate, save."
---

# The spec wizard

Your goal is not a filled-in template. It is a spec an agent can implement
correctly **without being able to ask the author anything**, because that is the
situation a Drone is actually in.

The flow is four phases. Most of the value is in phase C.

```
A. Gather      — cheap facts, fast, no interrogation yet
B. Draft       — you write the whole thing, they react
C. Interrogate — score, attack the weakest dimension, repeat  ← the real work
D. Validate    — form check, save, hand off
```

---

## Before anything: read the repo

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/detect-stack.sh
```

You now know the build, test, and lint commands and which convention files this
repo carries. **Never ask the user for something you can read.** Every question
spent on a retrievable fact is one you cannot spend on intent, which is the only
thing they know and you do not.

---

## Phase A — Gather

Be fast here. Do not interrogate yet; you have nothing to interrogate.

> "I'll build you a spec. A few quick questions, then I'll draft the whole thing
> and we'll sharpen it together."

**Skip anything they already told you.** If they opened with a detailed
description, take everything you can from it and ask only about what is missing.

1. **Kind** — feature, bugfix, workflow, or refactor. Load
   `templates/<kind>.md` as the skeleton and the closest file in `examples/` as
   the reference for depth.

   If **bugfix**, ask immediately whether the root cause is confirmed. If it is
   not, stop: an unconfirmed bug is an investigation, and a parallel swarm is the
   wrong tool for one — each agent will guess differently. Offer to diagnose it
   in this session instead.

2. **Identity**, in one message rather than three: a short kebab-case name (you
   prepend today's date for `spec_id`), an `area` — suggest two or three from the
   repo's top-level directories rather than asking cold — and an owner,
   defaulting to `git config user.email`.

3. **The ask, in their words.** "In a few sentences: what do you want to be
   true when this is done?" Take whatever they give you. Do not push yet.

---

## Phase B — Draft

**Write the entire spec yourself.** All sections, your best guess at each one.

For the Task Breakdown specifically: glob the directories involved and read
enough of the surrounding code to know which files a change of this shape
actually touches *in this repo*. A breakdown invented from the spec text alone
will claim files that do not exist and will miss the shared registration file
that breaks the ownership rule.

Then show it:

> "Here's the draft. I've guessed at several things — I'll point out which, and
> we'll fix what I got wrong."

Drafting first, rather than interviewing first, is deliberate. People correct a
concrete proposal far better than they generate one from a blank page, and it is
faster for both of you. The correction is where the real requirements come out.

---

## Phase C — Interrogate

Read `interrogation.md` now. It holds the stance, the malicious-compliance
technique, the question ladders per dimension, and how to handle a non-answer.
This phase is that protocol, run in a loop.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/score-spec.sh <draft-path>
```

The scorer returns a verdict per dimension, an `interrogate_next` list already
ordered by blast radius, and specific findings with evidence.

**The loop:**

1. Score the current draft.
2. If `overall` is `ready` → phase D.
3. Take the **first** dimension in `interrogate_next`. Ask two or three focused
   questions about that dimension only, using its ladder in `interrogation.md`.
4. Fold the answers in. Re-score. Repeat.

Work one dimension at a time and in the order given. The dimensions are not
independent — a weak Outcome makes the criteria weak by construction, so
questions about criteria asked before the Outcome is fixed get re-answered later
anyway.

**Show your evidence.** Do not say "the Outcome needs work". Say what is wrong
and why it bites:

> "Two things in the Outcome. It says 'handle errors gracefully' — I could catch
> everything and return 200, and be compliant. And it says 'improve performance'
> with no number, so nothing can tell us whether we succeeded. What does a
> failed request actually return, and what latency would make you unhappy?"

**Stop when** `overall` is `ready`, **or** two consecutive rounds produce no
improvement — say so, write what is still soft into the spec as an explicit
assumption, and move on — **or** the user tells you to stop, which is their call
and always wins. Note the weak dimensions in your handover so the risk is visible
rather than buried.

**Typical shape:** two to four rounds. One round means you got lucky or you are
not attacking hard enough. More than five means the work is not understood well
enough to specify, and the useful thing to say is that, not another question.

---

## Phase D — Validate and hand off

1. Write to `.swarm/specs/<spec_id>.md`.
2. `bash ${CLAUDE_PLUGIN_ROOT}/lib/validate-spec.sh <path>` — fix every error and
   re-run until `VALID`. Explain each fix, especially for rule 8, where the fix
   changes the task structure they just approved.
3. Address the warnings or say why you are leaving one.

The two gates are different and both must clear. The validator checks **form**:
sections present, tasks annotated, no file claimed twice. The scorer checks
**readiness**: whether the spec actually says anything. A perfectly-formed spec
can be empty of meaning, and `VALID` on its own is not a reason to stop.

Close with the shape of the run, not just the filename:

> "Saved to `.swarm/specs/<spec_id>.md`. Validates clean, readiness `ready`.
> 5 tasks across 3 waves — wave 1 runs T1, T2 and T3 in parallel.
> Run it with `/swarm .swarm/specs/<spec_id>.md`, or read it first."

If any dimension is still below bar, say so in that handover, in one line. The
operator is about to spend real money on this.

---

## The bar

Before you hand it over, ask yourself the only question that matters:

> If I gave this spec to a competent engineer who could not contact the author,
> would they build the right thing?

If the honest answer is "probably, if they guess well on a couple of points" —
name those points. That is what phase C was for, and an assumption written on the
page can be reviewed. One left in an agent's head cannot.
