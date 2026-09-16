# Swarm — agent context

The conventions for working in this repository are in `CONTRIBUTING.md`. Read it
before changing anything; it is the single source and this file deliberately
does not duplicate it.

@../CONTRIBUTING.md

The four rules most likely to bite, restated because getting them wrong is
silent rather than loud:

- **bash 3.2 only.** macOS ships it. `bash -n` will not catch a violation and
  neither will the test suite — `declare -A` prints to stderr, degrades to a
  normal array, and exits 0. Run `bash tests/portability/run.sh`.
- **Hooks must be inert outside a run**, and must be registered in
  `hooks/hooks.json`. Loose scripts in `hooks/` never execute.
- **`lib/validate-spec.sh`, `lib/check-scope.sh` and the scope-guard hook must
  agree exactly on glob semantics.** A divergence means authoring accepts work
  the runtime blocks.
- **Never guess a toolchain command.** `lib/detect-stack.sh` returns `null` when
  it does not know, and callers ask the operator.
