---
name: swarm-spec/interrogation
description: "The adversarial questioning protocol. Decides whether a spec is ready for an agent to implement, which dimension to attack next, and when to stop asking."
---

# Interrogation

Getting a spec written is easy. Getting one an agent can implement *correctly,
without being able to ask you anything*, is the hard part — and it is the only
part that matters, because that is the situation a Drone is actually in.

This file is the protocol for closing that gap.

---

## The stance

You are not collecting requirements. You are trying to break the spec.

For every section, the question you are answering is not "did they fill this
in?" It is:

> **Can I think of an implementation that satisfies every word of this spec and
> is still obviously not what they wanted?**

If you can, the spec is not done, and you have your next question — you do not
have to invent one, because the broken implementation *is* the question.

This is not pedantry. A Drone has no access to the author, no memory of the
meeting, and a strong bias toward producing something that looks complete. It
will resolve every ambiguity, silently, in whichever direction is easiest. Your
job is to resolve those ambiguities first, while it is still cheap.

---

## The core move: malicious compliance

The single most effective technique. Do not ask "can you be more specific?" —
that puts the work back on the user and usually returns a longer version of the
same vagueness. Instead, **show them the bad implementation their spec permits.**

> **User:** "Search results should be ordered sensibly."
>
> **Weak:** "Could you clarify what you mean by sensibly?"
>
> **Strong:** "As written, I could sort alphabetically by title and be fully
> compliant. I assume you mean relevance — but relevance to what? Term frequency
> in the title, recency, the customer's own history? Those give visibly different
> results for the same query."

The second version does three things the first does not: it proves the gap is
real rather than asserted, it gives the user something concrete to react to,
and it usually gets a precise answer in one round instead of three.

Use it whenever the scorer returns a hedge word. A hedge word is an ambiguity
with a polite face, and this is how you take the face off.

---

## Deciding whether to keep asking

Do not run a fixed script. Run `lib/score-spec.sh` and let it choose.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/score-spec.sh <draft-path>
```

It returns a verdict per dimension (`weak` / `adequate` / `ready`), an
`interrogate_next` list already ordered by blast radius, and specific findings
with the evidence behind each.

**The loop:**

1. Draft or update the spec.
2. Score it.
3. If `overall` is `ready` → stop asking and go to validation.
4. Otherwise take the **first** dimension in `interrogate_next` and ask about
   that one only.
5. Fold the answer in, re-score, repeat.

**Why one dimension at a time.** The dimensions are not independent. A weak
Outcome makes the criteria weak by construction — they inherit its vagueness —
so questions about criteria asked before the Outcome is fixed are wasted, and
often get re-answered differently afterwards. `interrogate_next` is ordered by
blast radius for this reason: outcome, criteria, decomposition, constraints,
boundaries, context. Fix the thing whose weakness contaminates the most.

**Ask two or three questions per round, not one and not eight.** One round-trip
per question is slow and feels like an interrogation in the bad sense. Eight at
once gets three real answers and five shrugs. Two or three focused questions
about a single dimension is the shape people actually answer well.

**Stop when any of these is true:**

- `overall` is `ready`.
- Two consecutive rounds produce no dimension improvement. You are extracting
  nothing further; say so plainly, record what is still soft as an explicit
  assumption in the spec, and move on.
- The user tells you to stop. It is their spec. Note the weak dimensions in your
  handover so the risk is visible rather than buried, and proceed.

**Never stop just because the validator passes.** `validate-spec.sh` checks
form: is every section present, is every task annotated, does any file appear
twice. A spec can be perfectly formed and still say nothing. Form and readiness
are different questions and both gates must clear.

---

## What to ask, by dimension

Each ladder escalates. Start at the top; go down only if the answer does not
land.

### Outcome — weak

The most expensive dimension to get wrong, because everything else is derived
from it.

1. "If I shipped this and you tested it yourself, what would you actually do to
   check it worked? Walk me through it."
   *Their answer is the Outcome. People describe behaviour fluently and write it
   badly.*
2. "Who notices this change — an end user, an operator, another service? What do
   they see that they did not see before?"
3. Malicious compliance: "Here's an implementation that satisfies what you wrote
   and is clearly wrong: \<sketch it\>. What rules it out?"
4. If it is still mechanism rather than result: "That is how it works. What
   changes for whoever is on the other side of it?"

### Criteria — weak

1. "What would make you reject this in review, even with all tests green?"
   *The best source of real criteria. People know what would fail; they rarely
   write it down.*
2. For each behaviour in the Outcome: "When \<trigger\>, what should the system
   do? And what is the name of the test that would catch it if it didn't?"
3. The discrimination test, applied out loud: "That criterion passes today,
   before we change anything. What is a check that fails now and passes after?"
4. "What happens on the unhappy path — the input is malformed, the dependency is
   down, it runs twice? Any of those worth a criterion?"

### Decomposition — weak

Do not ask the user to decompose. Read the repo, propose, and have them correct.

1. "Here's how I would split it: \<tasks with file ownership\>. Wave 1 runs
   T1 and T2 in parallel. Is the file ownership right?"
2. On a shared-file collision: "T2 and T3 both need \<file\>. That breaks the
   parallelism guarantee. Are these really one task, or does one produce
   something the other consumes?"
3. On a glob: "T1 claims `src/api/*.ts`. Which files is that today? If it grows
   later it will start overlapping T2 without anyone noticing."
4. If everything is sequential: "This is a chain, not a swarm. Running it in one
   session will be faster and cheaper. Do you want to do that instead?"

### Constraints — weak

1. Category sweep, skipping what plainly does not apply: "Anything to say about
   performance, backwards compatibility, data handling, authorization, tenancy,
   or operational limits? A no is a fine answer — I'll record it."
2. On an unquantified constraint: "'Fast' is not checkable. What number would
   make you unhappy if we exceeded it?" *A rough number beats no number; you can
   always widen it.*
3. On an instruction: "You wrote 'use Redis'. If I write that down, an agent will
   use Redis even where it is the wrong call. What property do you actually need
   — durability across restarts, expiry, something else?"
4. "What would make this unshippable even if it worked?"

### Boundaries — weak

Seed this yourself. Almost nobody produces it cold, and almost everybody
recognises it instantly.

1. "Looking at the repo, this work sits next to \<X\>, \<Y\>, \<Z\>. Are any of
   those in scope, or should I fence them off?"
2. "Is there a tidy-up here you'd be annoyed to find in this PR?"
3. "Anything an agent might reasonably think is part of this that isn't?"

### Context — weak

1. "Has any of this already been decided or argued about? I want to stop four
   agents independently re-deciding it."
2. "Was anything considered and rejected? Knowing what not to do is worth as much
   as knowing what to do."
3. "Is there a ticket, ADR, or thread I should point at?"
4. For a bugfix with no confirmed cause: **stop.** "The cause isn't established
   yet. That makes this an investigation, and a parallel swarm is the wrong tool
   for one — the agents will each guess differently. Want to diagnose it here
   first?"

---

## When the answer is not an answer

**"I don't know."** Legitimate, and often the most useful thing they can say.
Offer two or three concrete options with their consequences and let them pick.
If they still cannot, write it into the spec as an explicit open question and
flag it — an assumption on the page can be reviewed; one in an agent's head
cannot.

**"Whatever you think is best."** Sometimes true delegation, sometimes fatigue.
Make the call, state it as a decision, and show it: "I'll assume X. That means Y.
Say if that's wrong." Do not silently decide — the point of the spec is that
decisions are visible.

**A longer version of the same vagueness.** Stop asking open questions. Switch
to malicious compliance, or offer a forced choice between two concrete readings.

**Scope creep mid-interview.** Write the new thing down, then ask directly:
"That's a real requirement but it's a different change. In this spec, or the
next one?" Both answers are fine; an unrecorded answer is not.

**Impatience — "just write it".** Respect it, and be honest about the trade in
one sentence: "Understood. The Outcome is still vague enough that an agent could
build the wrong thing — I'll write my assumption into the spec so it's visible
in review." Then do exactly that and move on. Do not lecture, and do not ask
again.

---

## What not to do

- **Do not interrogate someone who already told you.** If they opened with three
  detailed paragraphs, draft the entire spec from it, score it, and ask only
  about what the scorer flags. Running a wizard at someone who has already done
  the work is the fastest way to make them stop using this.
- **Do not ask what you can read.** Never ask for the test command, the directory
  layout, the language, or the conventions. Run `detect-stack.sh` and glob the
  tree. Every question you spend on retrievable facts is one you cannot spend on
  intent, which is the only thing they know and you do not.
- **Do not ask for completeness' sake.** A dimension the scorer rates `ready`
  needs no question. Padding the interview to look thorough trains the user to
  skim.
- **Do not accept your own draft as evidence.** When you have written most of the
  spec yourself, the scorer is grading your prose, not their intent. Say what you
  assumed and make them confirm it explicitly.
- **Do not confuse length with readiness.** A long spec full of hedges scores
  worse than a short sharp one, and should.
