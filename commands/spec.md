---
description: "Author or repair a swarm-spec — the executable specification the swarm consumes"
argument-hint: "[path-to-existing-spec.md] or \"<what you want to build>\""
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

Invoke the `swarm-spec` skill and follow it directly.

The operator's input is: `$ARGUMENTS`

- **A path to an existing spec** → validate it with `lib/validate-spec.sh` and
  repair every error, explaining each fix.
- **A description** → draft the spec from it, asking only about genuine gaps.
- **Empty** → run the wizard in `skills/swarm-spec/wizard.md`.
