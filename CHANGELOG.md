# Changelog

## 0.4.0 — 2026-09-16

Closes two of the gaps `docs/orchestration.md` section 7 named as open —
cross-run isolation and wave-level resumption — and narrows a third, semantic
conflict detection, without closing it. Adds a fourth capability, independent
spec grading, that section 7 never listed because it wasn't framed as a gap
until the interrogation protocol's own prior decisions said building it as
only a document was a mistake. Cost accounting and spec-to-code drift
detection remain open; both still need data this plugin cannot observe.

### Added

- **Run locking.** `lib/run-lock.sh` takes a repository-scoped lock (keyed off
  `git rev-parse --git-common-dir`, so it holds across every worktree of one
  repository, not just the current checkout) before the orchestrator touches
  `.swarm/`. A second run against the same repo is refused, naming the run id
  already holding the lock, instead of two runs sharing `task-graph.json` and
  corrupting each other's state. A lock left by a dead process is reclaimable,
  but only by explicit operator action — the orchestrator never reclaims one on
  its own.
- **Wave-level resumption.** `lib/resume-state.sh` records each task the
  instant its Drone finishes and each wave the instant it clears QA — never
  buffered to the end of the run, because a mid-run death is exactly the case
  this exists for. A fresh orchestrator process reads that state, cross-checks
  it against which task branches actually still exist in git, and reports the
  wave to resume from instead of restarting a verified run from wave 1. A wave
  recorded only partially complete is surfaced to the operator to decide —
  reuse the existing task branches or rebuild them — rather than the
  orchestrator picking for them.
- **Pre-merge integration checking.** `lib/check-integration.sh` runs before
  the merge, in orchestrator phase 4, and extracts symbols each task branch
  removed, cross-referencing them against what every other branch still calls.
  A collision names the symbol and both tasks and blocks the merge pending an
  operator decision. It is textual and heuristic by design — a real
  cross-language type checker is out of proportion for a plugin with no build
  step of its own — and it reports an unrecognised file extension as a coverage
  gap rather than a silent pass. It narrows, but does not close, the
  semantic-conflict gap described in `docs/orchestration.md` section 4; the
  merge build remains the backstop.
- **The Interrogator agent** (`agents/interrogator.md`, "the Changeling") — a
  fresh-context agent that reads only a finished spec and the scorer's output,
  tries to describe a compliant-but-wrong implementation, and reports blocking
  ambiguities a Drone would otherwise have to guess. `/spec` now dispatches it
  once the mechanical scorer reports `ready`, because the session that drafted
  the spec is structurally the wrong session to grade it. `BLOCKING` findings
  send the spec back to interrogation; `NON_BLOCKING` findings are reported,
  not enforced. The orchestrator can also dispatch it as an optional gate
  before a wide or expensive run.

### Changed

- **`docs/orchestration.md`** section 7 now reflects the above: cross-run
  isolation and wave-level resumption move out of "what is not built"; the
  semantic-conflict paragraph in section 4 references the new pre-merge check
  while staying honest that a textual heuristic does not catch everything. Cost
  accounting and spec-to-code drift detection stay in section 7, unchanged —
  they are still true.

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
