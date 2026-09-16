# Changelog

## 0.3.0 — 2026-09-16

First standalone release. Extracted from a private monorepo, generalised to run
against any repository, and merged with the spec builder that previously lived in
a sibling plugin. The spec schema is `swarm-spec` v2.0 and is not compatible with
the pre-extraction format.

### Added

- **Integrated spec builder.** `/spec`, the `swarm-spec` skill, a guided wizard,
  four templates, and worked examples. Authoring and execution now live in one
  plugin; the orchestrator no longer needs a sibling installed to accept a
  structured spec.
- **`lib/score-spec.sh` and the interrogation protocol.** The spec builder no
  longer just collects answers — it drafts, then adversarially attacks its own
  draft. The scorer emits mechanical readiness signals a model cannot argue with
  (hedge words, unquantified constraints, criteria naming no command,
  instructions posing as constraints, glob scopes, non-discriminating criteria),
  per dimension, with an `interrogate_next` list ordered by blast radius.
  `skills/swarm-spec/interrogation.md` turns those signals into questions, using
  malicious compliance — showing the user the wrong implementation their spec
  permits — and defines when to keep asking and when to stop.
- **`lib/validate-spec.sh`** — deterministic schema validation. Replaces an
  LLM-based validator: schema checking is exactly the wrong job for a language
  model, since it is non-deterministic, costs a model call, and can be argued
  out of a finding.
- **`lib/detect-stack.sh`** — infers build, test, and lint commands for Node,
  .NET, Rust, Go, Python, Maven, Gradle, Ruby, and Make, and lists the repo's
  convention files. Returns `null` rather than guessing.
- **`/spec` command** and a fourth template, `refactor`.
- **Real test suites** — 57 tests across `lib`, `hooks`, `scoring`, and
  `spec-validation`, exercising the actual scripts against generated
  repositories, real hook payloads, and specs broken one dimension at a time.
- **`docs/orchestration.md`** — the orchestration model, including what it does
  not guarantee.

### Fixed

- **Scope guard let globs cross directory boundaries.** Bash's `==` glob matches
  `/` with `*`, so a scope of `src/api/*.ts` silently claimed
  `src/api/v2/deep/handler.ts`. Two scopes that read as disjoint could overlap at
  runtime, voiding the no-conflict guarantee without any visible failure. `*` and
  `?` are now bounded to one path segment and `**` is the explicit way to cross.
- **Scope guard could be escaped by path traversal.** Relative and `..`-bearing
  paths are now normalised and anything resolving outside the repository root is
  blocked.
- **Rule 8 compared raw strings.** `src/api/*.ts` and `src/api/routes.ts` are
  different strings claiming the same file, and the validator passed it. Overlap
  detection is now glob-aware and matches the hook's semantics exactly.
- **Dependency validation matched against whole task lines,** so `(after: T9)`
  satisfied itself by finding `T9` in its own text. Edges now resolve against the
  set of declared task ids, after every task has been read.
- **Command scripts used monorepo-relative paths** that do not exist once the
  plugin is installed from a cache directory. All paths now use
  `${CLAUDE_PLUGIN_ROOT}`.

### Changed

- **Stack-agnostic throughout.** The hardcoded domain map of one company's
  business areas and the .NET-assuming verification map are gone, replaced by
  stack detection. The spec's `domain` enum became a free-form `area`, so specs
  written outside the originating organisation are no longer invalid on arrival.
- **Config lives at `~/.config/swarm/config.yaml`**, overridable with
  `SWARM_CONFIG`. A `merge_strategy` key was added, defaulting to `serialized`.
- **Commands are `/swarm`, `/swarm-status`, and `/spec`** — the previous
  namespace prefix referred to a plugin marketplace that no longer exists.
- **Model pins became aliases** (`opus`, `sonnet`) so the roster tracks the
  current generation instead of a stale snapshot id.
- **Git operations in the review and merge phases are serialized.** Concurrent
  git commands across worktrees of one repository contend on shared `.git`
  metadata and can corrupt it.
- **Reviewer moved from Haiku to Sonnet.** Cross-task consistency review is the
  one judgement no other agent in the pipeline can make.
- **The orchestrator compiles structured specs itself** instead of spending an
  Opus call re-deriving a decomposition the author already wrote.

### Removed

- The sibling-plugin detection and tier-gating libraries, which depended on
  plugins that are not part of this repository.
- The v0.1 replay test suite, which only asserted that its own checked-in JSON
  fixtures were valid JSON and never invoked the orchestrator.
