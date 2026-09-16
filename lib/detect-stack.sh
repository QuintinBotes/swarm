#!/usr/bin/env bash
# detect-stack.sh — Infer the repo's build, test, and lint commands.
#
# This replaces a hand-maintained domain map. A domain map encodes one
# organisation's business areas and rots the moment you point the swarm at a
# different repo. What the orchestrator actually needs is narrower and
# universal: how do I build this, how do I test it, how do I lint it.
#
# Usage: detect-stack.sh [repo-root]   (default: current directory)
# Emits JSON. Every field may be null — a null means "ask the operator",
# never "skip the check".
set -uo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT" 2>/dev/null || { echo '{"error":"unreadable repo root"}'; exit 0; }

ECOSYSTEMS=""
BUILD=""
TEST=""
LINT=""

_has() { [[ -e "$1" ]]; }
# Returns the shallowest match, so a solution at src/App.sln wins over one
# buried in tools/SomeHelper/SomeHelper.sln.
_find() {
  find . -maxdepth "$2" -name "$1" -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null \
    | awk -F/ '{print NF"\t"$0}' | sort -n | head -1 | cut -f2-
}

# --- Node / TypeScript ------------------------------------------------------
if _has package.json; then
  ECOSYSTEMS="${ECOSYSTEMS} node"
  pm="npm"
  _has pnpm-lock.yaml && pm="pnpm"
  _has yarn.lock && pm="yarn"
  _has bun.lockb && pm="bun"

  _script() { grep -q "\"$1\"[[:space:]]*:" package.json 2>/dev/null; }
  _script build && BUILD="${pm} run build"
  _script test  && TEST="${pm} test"
  _script lint  && LINT="${pm} run lint"
  [[ -z "$LINT" ]] && _script typecheck && LINT="${pm} run typecheck"
fi

# --- .NET -------------------------------------------------------------------
sln=$(_find '*.sln' 3); [[ -z "$sln" ]] && sln=$(_find '*.slnx' 3)
csproj=$(_find '*.csproj' 4)
if [[ -n "$sln" || -n "$csproj" ]]; then
  ECOSYSTEMS="${ECOSYSTEMS} dotnet"
  [[ -z "$BUILD" ]] && BUILD="dotnet build${sln:+ $sln}"
  [[ -z "$TEST"  ]] && TEST="dotnet test${sln:+ $sln}"
  [[ -z "$LINT"  ]] && LINT="dotnet format --verify-no-changes"
fi

# --- Rust -------------------------------------------------------------------
if _has Cargo.toml; then
  ECOSYSTEMS="${ECOSYSTEMS} rust"
  [[ -z "$BUILD" ]] && BUILD="cargo build"
  [[ -z "$TEST"  ]] && TEST="cargo test"
  [[ -z "$LINT"  ]] && LINT="cargo clippy -- -D warnings"
fi

# --- Go ---------------------------------------------------------------------
if _has go.mod; then
  ECOSYSTEMS="${ECOSYSTEMS} go"
  [[ -z "$BUILD" ]] && BUILD="go build ./..."
  [[ -z "$TEST"  ]] && TEST="go test ./..."
  [[ -z "$LINT"  ]] && LINT="go vet ./..."
fi

# --- Python -----------------------------------------------------------------
if _has pyproject.toml || _has setup.py || _has requirements.txt; then
  ECOSYSTEMS="${ECOSYSTEMS} python"
  runner="python -m"
  _has uv.lock && runner="uv run"
  _has poetry.lock && runner="poetry run"
  [[ -z "$TEST" ]] && TEST="${runner} pytest"
  if _has pyproject.toml && grep -q "ruff" pyproject.toml 2>/dev/null; then
    [[ -z "$LINT" ]] && LINT="${runner} ruff check ."
  fi
fi

# --- JVM --------------------------------------------------------------------
if _has pom.xml; then
  ECOSYSTEMS="${ECOSYSTEMS} maven"
  [[ -z "$BUILD" ]] && BUILD="mvn -B compile"
  [[ -z "$TEST"  ]] && TEST="mvn -B test"
elif _has build.gradle || _has build.gradle.kts; then
  ECOSYSTEMS="${ECOSYSTEMS} gradle"
  g="gradle"; _has gradlew && g="./gradlew"
  [[ -z "$BUILD" ]] && BUILD="${g} build -x test"
  [[ -z "$TEST"  ]] && TEST="${g} test"
fi

# --- Ruby -------------------------------------------------------------------
if _has Gemfile; then
  ECOSYSTEMS="${ECOSYSTEMS} ruby"
  [[ -z "$TEST" ]] && TEST="bundle exec rspec"
  [[ -z "$LINT" ]] && LINT="bundle exec rubocop"
fi

# --- Make, as a last resort -------------------------------------------------
if _has Makefile; then
  ECOSYSTEMS="${ECOSYSTEMS} make"
  grep -qE '^build:' Makefile 2>/dev/null && [[ -z "$BUILD" ]] && BUILD="make build"
  grep -qE '^test:'  Makefile 2>/dev/null && [[ -z "$TEST"  ]] && TEST="make test"
  grep -qE '^lint:'  Makefile 2>/dev/null && [[ -z "$LINT"  ]] && LINT="make lint"
fi

# --- Repo conventions the agents must read ----------------------------------
CONVENTIONS=""
for f in CLAUDE.md AGENTS.md CONTRIBUTING.md .editorconfig; do
  _has "$f" && CONVENTIONS="${CONVENTIONS} $f"
done
_has .claude/rules && CONVENTIONS="${CONVENTIONS} .claude/rules/"
_has .cursor/rules && CONVENTIONS="${CONVENTIONS} .cursor/rules/"

_jstr() { [[ -z "$1" ]] && echo "null" || echo "\"$1\""; }
# Turns a space-separated list into a JSON array. bash 3.2 has no namerefs,
# and macOS still ships bash 3.2, so arrays are kept as plain strings.
_jarr() {
  local items="$1"
  local out="" item
  for item in $items; do
    out="${out}\"${item}\","
  done
  printf '[%s]' "${out%,}"
}

printf '{"ecosystems":%s,"build":%s,"test":%s,"lint":%s,"conventions":%s}\n' \
  "$(_jarr "$ECOSYSTEMS")" "$(_jstr "$BUILD")" "$(_jstr "$TEST")" "$(_jstr "$LINT")" "$(_jarr "$CONVENTIONS")"
