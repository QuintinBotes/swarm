#!/usr/bin/env bash
# run.sh — smoke tests for the shell libraries.
# These exercise the real scripts against real temporary repositories rather
# than asserting over checked-in fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../../lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    PASS=$((PASS + 1)); echo "ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $name"
    echo "       expected to contain: $expected"
    echo "       actual:              $actual"
  fi
}

# --- detect-stack -----------------------------------------------------------
mkdir -p "$TMP/node"
cat > "$TMP/node/package.json" <<'JSON'
{"name":"x","scripts":{"build":"tsc","test":"vitest","lint":"eslint ."}}
JSON
check "detect-stack finds npm scripts" '"build":"npm run build"' "$(bash "$LIB/detect-stack.sh" "$TMP/node")"

mkdir -p "$TMP/node-pnpm"
cp "$TMP/node/package.json" "$TMP/node-pnpm/"
touch "$TMP/node-pnpm/pnpm-lock.yaml"
check "detect-stack picks the right package manager" '"test":"pnpm test"' "$(bash "$LIB/detect-stack.sh" "$TMP/node-pnpm")"

mkdir -p "$TMP/rust"
printf '[package]\nname="x"\n' > "$TMP/rust/Cargo.toml"
check "detect-stack handles rust" '"lint":"cargo clippy -- -D warnings"' "$(bash "$LIB/detect-stack.sh" "$TMP/rust")"

mkdir -p "$TMP/go"
printf 'module x\n' > "$TMP/go/go.mod"
check "detect-stack handles go" '"test":"go test ./..."' "$(bash "$LIB/detect-stack.sh" "$TMP/go")"

mkdir -p "$TMP/deep/src"
touch "$TMP/deep/src/App.sln"
mkdir -p "$TMP/deep/tools/Helper"
touch "$TMP/deep/tools/Helper/Helper.sln"
check "detect-stack prefers the shallowest solution" 'src/App.sln' "$(bash "$LIB/detect-stack.sh" "$TMP/deep")"

mkdir -p "$TMP/empty"
check "detect-stack is honest about an unknown stack" '"build":null' "$(bash "$LIB/detect-stack.sh" "$TMP/empty")"

mkdir -p "$TMP/conv"
touch "$TMP/conv/CLAUDE.md" "$TMP/conv/AGENTS.md"
check "detect-stack lists convention files" '"CLAUDE.md","AGENTS.md"' "$(bash "$LIB/detect-stack.sh" "$TMP/conv")"

# --- spec-detect ------------------------------------------------------------
cat > "$TMP/spec.md" <<'MD'
---
schema: swarm-spec
schema_version: "2.0"
spec_id: 2026-01-01_thing
kind: feature
status: Draft
owner: a@b.c
area: billing
---
MD
check "spec-detect reads swarm-spec frontmatter" '"area":"billing"' "$(bash "$LIB/spec-detect.sh" "$TMP/spec.md")"

sed 's/swarm-spec/some-other-spec/' "$TMP/spec.md" > "$TMP/foreign.md"
check "spec-detect returns null for a foreign schema" 'null' "$(bash "$LIB/spec-detect.sh" "$TMP/foreign.md")"

printf 'just prose, no frontmatter\n' > "$TMP/prose.md"
check "spec-detect returns null for prose" 'null' "$(bash "$LIB/spec-detect.sh" "$TMP/prose.md")"
check "spec-detect returns null for a missing file" 'null' "$(bash "$LIB/spec-detect.sh" "$TMP/nope.md")"

# --- load-user-config -------------------------------------------------------
check "config falls back to defaults" '"config_source":"defaults"' \
  "$(SWARM_CONFIG="$TMP/none.yaml" bash "$LIB/load-user-config.sh")"

cat > "$TMP/config.yaml" <<'YAML'
parallel_agents: 8
qa_enabled: false
merge_strategy: octopus
YAML
out="$(SWARM_CONFIG="$TMP/config.yaml" bash "$LIB/load-user-config.sh")"
check "config reads parallel_agents" '"parallel_agents":8' "$out"
check "config reads booleans"        '"qa_enabled":false'  "$out"

cat > "$TMP/bad.yaml" <<'YAML'
parallel_agents: banana
merge_strategy: teleport
YAML
out="$(SWARM_CONFIG="$TMP/bad.yaml" bash "$LIB/load-user-config.sh")"
check "config rejects a junk integer"  '"parallel_agents":4'          "$out"
check "config rejects a junk strategy" '"merge_strategy":"serialized"' "$out"

echo
echo "lib: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
