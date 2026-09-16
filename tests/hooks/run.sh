#!/usr/bin/env bash
# run.sh — scope-guard hook tests.
# The PreToolUse scope guard is the runtime half of the file-ownership
# guarantee. If it lets a write through, the whole no-conflict claim is void,
# so it is tested against a real .swarm directory and real hook payloads.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/../../hooks/pre-tool-use-scope-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

mkdir -p "$TMP/repo/.swarm"
cat > "$TMP/repo/.swarm/task-graph.json" <<'JSON'
{
  "runId": "2026-09-16T10-00-00_test",
  "specSource": "inline",
  "waves": [
    { "wave": 1, "tasks": [
      { "taskId": "T1", "title": "t", "description": "d",
        "fileScope": ["src/one.ts", "src/nested/*.ts", "src/newdir/", "src/deep/**/*.ts"],
        "verificationCriteria": ["c"], "dependsOn": [] },
      { "taskId": "T2", "title": "t", "description": "d",
        "fileScope": ["src/two.ts"],
        "verificationCriteria": ["c"], "dependsOn": [] }
    ]}
  ]
}
JSON
echo "T1" > "$TMP/repo/.swarm/current-task-id"

# Runs the guard from inside the fake repo and reports allow/block.
guard() {
  local tool="$1" path="$2"
  local payload
  payload=$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$path")
  ( cd "$TMP/repo" && echo "$payload" | bash "$GUARD" >/dev/null 2>&1 \
      && echo ALLOW || echo BLOCK )
}

expect() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    PASS=$((PASS + 1)); echo "ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $name — expected $want, got $got"
  fi
}

R="$TMP/repo"
expect "allows an exact in-scope path"        ALLOW "$(guard Write "$R/src/one.ts")"
expect "blocks another task's file"           BLOCK "$(guard Write "$R/src/two.ts")"
expect "blocks an unclaimed file"             BLOCK "$(guard Write "$R/src/three.ts")"
expect "blocks an unclaimed file via Edit"    BLOCK "$(guard Edit  "$R/src/three.ts")"
expect "allows a glob match"                  ALLOW "$(guard Write "$R/src/nested/a.ts")"
expect "blocks a glob crossing a directory"   BLOCK "$(guard Write "$R/src/nested/deep/a.ts")"
expect "allows a directory scope"             ALLOW "$(guard Write "$R/src/newdir/new.ts")"
expect "blocks a sibling of a directory scope" BLOCK "$(guard Write "$R/src/newdirx/new.ts")"
expect "allows ** crossing directories"       ALLOW "$(guard Write "$R/src/deep/a/b/c.ts")"
expect "** still respects the extension"      BLOCK "$(guard Write "$R/src/deep/a/b/c.md")"
expect "ignores non-write tools"              ALLOW "$(guard Read  "$R/src/two.ts")"
expect "blocks traversal out of the repo"     BLOCK "$(guard Write "$R/../escape.ts")"

# No active swarm anywhere above cwd -> the guard must not interfere.
mkdir -p "$TMP/plain/src"
payload='{"tool_name":"Write","tool_input":{"file_path":"src/anything.ts"}}'
got=$( cd "$TMP/plain" && echo "$payload" | bash "$GUARD" >/dev/null 2>&1 && echo ALLOW || echo BLOCK )
expect "allows everything with no active swarm" ALLOW "$got"

# Swarm present but no current-task-id -> not a Drone worktree, allow.
rm -f "$TMP/repo/.swarm/current-task-id"
expect "allows when no task id is assigned"   ALLOW "$(guard Write "$R/src/three.ts")"
echo "T1" > "$TMP/repo/.swarm/current-task-id"

# Task id that is not in the graph -> fail closed.
echo "T99" > "$TMP/repo/.swarm/current-task-id"
expect "fails closed on an unknown task id"   BLOCK "$(guard Write "$R/src/one.ts")"

echo
echo "hooks: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
