# Contributing to Swarm

A Claude Code plugin. No compiled code — bash, markdown, and JSON schemas. To
work on it, clone it and run `claude --plugin-dir .` from the checkout.

```bash
bash tests/run-all.sh          # every suite
bash tests/portability/run.sh  # the one that matters most; see Hard rules
claude plugin validate . --strict
```

## Commands

- `/swarm <spec-or-description>` — run the pipeline (compile → implement → QA → review → merge)
- `/swarm-status` — live dashboard for an active run
- `/spec [path-or-description]` — author, repair, or validate a spec

## Layout

- `agents/` — one specialist role per file. Frontmatter `model:` uses aliases
  (`opus`, `sonnet`), never pinned snapshot ids, so the roster tracks the current
  generation.
- `skills/swarm/` — orchestration prompt and the task-graph schema
- `skills/swarm-spec/` — the spec format and the spec builder: schema,
  interrogation protocol, wizard, templates, examples
- `commands/` — thin slash-command entry points that delegate to a skill
- `hooks/` — bash fired by Claude Code hook events
- `lib/` — shell helpers, callable standalone and independently testable
- `tests/` — `bash tests/run-all.sh`

## Hard rules

- **Bash 3.2.** macOS still ships it. No associative arrays, no namerefs, no
  `readarray`. Test with `/bin/bash`, not a Homebrew bash.
- **Hooks must be inert outside a run.** Every hook checks for
  `.swarm/task-graph.json` and exits 0 immediately when there is none. A hook
  that misfires in an unrelated session is worse than a hook that does nothing.
- **The scope guard fails closed.** An unknown task id, an unresolvable path, or
  a path outside the repo root blocks the write. Never weaken this to unblock a
  stuck run — a stuck run is the hook doing its job.
- **Glob semantics are segment-bounded.** `*` and `?` stay within one path
  segment; `**` crosses directories. `lib/validate-spec.sh` and
  `hooks/pre-tool-use-scope-guard.sh` must agree exactly — they enforce one
  invariant at two different times, and a divergence means the authoring check
  passes work the runtime check will block.
- **Never guess a toolchain command.** `lib/detect-stack.sh` returns `null` when
  it does not know, and callers ask the operator. QA reports `SKIPPED`, never
  `PASS`, for a check it did not run.
- **Paths in prompts use `${CLAUDE_PLUGIN_ROOT}`.** The plugin is installed to a
  cache directory, not the user's repo. A relative path resolves against their
  working tree and finds nothing.

- **Form and readiness are separate gates.** `lib/validate-spec.sh` answers "is
  this well-formed" with a pass or fail. `lib/score-spec.sh` answers "does this
  say anything" per dimension. Neither substitutes for the other, and a spec that
  is `VALID` can still be unimplementable.
- **Readiness signals stay mechanical.** Everything in `score-spec.sh` is
  countable: a hedge word is present or absent, a constraint has a number or it
  does not. Judgement belongs in `interrogation.md`, where a model applies it. A
  signal a model can argue with is not a signal.

## Changing the spec schema

The schema is a contract with five consumers: `lib/validate-spec.sh`,
`lib/score-spec.sh`, `lib/spec-detect.sh`, the orchestrator's compile step, and
the wizard. A change touches all five plus `schema.md`, the templates, and the
examples — and needs a fixture in `tests/spec-validation/fixtures/` proving the
new rule fires.

Bump `schema_version` for anything that invalidates an existing spec.

## Adding a readiness signal

A new signal needs a case in `tests/scoring/run.sh` that mutates the baseline
spec in exactly one way and asserts that signal fires. Mutating two things at
once proves nothing about either. A signal that cannot be broken in isolation is
a signal that will produce false positives in the field.

## Adding a test

Each suite is `tests/<name>/run.sh`, exits non-zero on failure, and is picked up
by `run-all.sh` automatically. Tests exercise the real scripts against real
temporary directories. A test that only asserts over a checked-in fixture proves
the fixture is well-formed and nothing else.


## Before opening a pull request

1. `bash tests/run-all.sh` passes.
2. `claude plugin validate . --strict` passes.
3. `shellcheck --severity=warning --shell=bash $(find . -name '*.sh' -not -path './.git/*')` is clean.
4. If you changed a hook, confirm `claude plugin details` still reports three
   hooks against a real install. A hook that is not registered is inert, and
   nothing else in the repository will tell you.

CI runs all of this on macOS and Linux. The matrix is not thoroughness for its
own sake — see Hard rules for why a Linux-only check would be actively
misleading here.

## A note on tests

A test that cannot fail proves nothing. Every suite here was written by breaking
the thing it covers, watching the test fail, and then restoring it. If you add a
test, do the same, and say so in the pull request.
