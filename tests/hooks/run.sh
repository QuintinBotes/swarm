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

# --- stream placement -------------------------------------------------------
# Claude Code reads a blocking hook's feedback from stderr. A reason written to
# stdout is discarded, so the write is refused with no explanation — worse than
# not blocking, because the agent cannot act on it.
echo "T1" > "$TMP/repo/.swarm/current-task-id"
payload=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$R/src/three.ts")

guard_stdout=$( cd "$R" && printf '%s' "$payload" | bash "$GUARD" 2>/dev/null )
guard_stderr=$( cd "$R" && printf '%s' "$payload" | bash "$GUARD" 2>&1 >/dev/null )

if [[ -z "$guard_stdout" ]]; then
  PASS=$((PASS + 1)); echo "ok   a blocked write writes nothing to stdout"
else
  FAIL=$((FAIL + 1)); echo "FAIL a blocked write wrote to stdout: ${guard_stdout:0:50}"
fi

if [[ "$guard_stderr" == *"BLOCKED"* && "$guard_stderr" == *"three.ts"* ]]; then
  PASS=$((PASS + 1)); echo "ok   a blocked write explains itself on stderr"
else
  FAIL=$((FAIL + 1)); echo "FAIL stderr did not carry the block reason: ${guard_stderr:0:50}"
fi

# --- inertness outside a run ------------------------------------------------
# A hook that misfires in an unrelated session is worse than one that does
# nothing. Outside a swarm run every hook must exit 0 and stay silent.
mkdir -p "$TMP/bare/src"
for hook in "$GUARD" "${HERE}/../../hooks/post-write-qa-signal.sh" "${HERE}/../../hooks/stop-gate.sh"; do
  name=$(basename "$hook")
  combined=$( cd "$TMP/bare" && printf '{"tool_name":"Write","tool_input":{"file_path":"src/x.ts"}}' \
                | bash "$hook" 2>&1 )
  rc=$( cd "$TMP/bare" && printf '{"tool_name":"Write","tool_input":{"file_path":"src/x.ts"}}' \
                | bash "$hook" >/dev/null 2>&1; echo $? )
  if [[ "$rc" == "0" && -z "$combined" ]]; then
    PASS=$((PASS + 1)); echo "ok   ${name} is inert with no active run"
  else
    FAIL=$((FAIL + 1)); echo "FAIL ${name} was not inert (exit ${rc}, output: ${combined:0:40})"
  fi
done

# --- stop gate must not loop forever ----------------------------------------
# Without honouring stop_hook_active, a QA state that can never be satisfied
# blocks every turn until the runtime's consecutive-block cap intervenes.
STOP="${HERE}/../../hooks/stop-gate.sh"
mkdir -p "$TMP/repo/.swarm/qa-status"
touch "$TMP/repo/.swarm/qa-status/T1.pending"
rm -f "$TMP/repo/.swarm/qa-status/T1.passed"

rc_first=$( cd "$R" && printf '{"stop_hook_active":false}' | bash "$STOP" >/dev/null 2>&1; echo $? )
expect "stop gate holds the turn when QA is pending" "2" "$rc_first"

rc_second=$( cd "$R" && printf '{"stop_hook_active":true}' | bash "$STOP" >/dev/null 2>&1; echo $? )
expect "stop gate stands down once it has already blocked" "0" "$rc_second"

stop_stdout=$( cd "$R" && printf '{"stop_hook_active":false}' | bash "$STOP" 2>/dev/null )
if [[ -z "$stop_stdout" ]]; then
  PASS=$((PASS + 1)); echo "ok   stop gate writes nothing to stdout"
else
  FAIL=$((FAIL + 1)); echo "FAIL stop gate wrote to stdout: ${stop_stdout:0:40}"
fi

touch "$TMP/repo/.swarm/qa-status/T1.passed"
rc_passed=$( cd "$R" && printf '{"stop_hook_active":false}' | bash "$STOP" >/dev/null 2>&1; echo $? )
expect "stop gate allows the turn once QA has passed" "0" "$rc_passed"

# --- hook registration ------------------------------------------------------
# Loose .sh files in hooks/ are never discovered. Without this manifest the
# scope guard never runs for an installed user, which is how it shipped.
MANIFEST="${HERE}/../../hooks/hooks.json"
if [[ -f "$MANIFEST" ]]; then
  PASS=$((PASS + 1)); echo "ok   hooks.json exists at the plugin root"
else
  FAIL=$((FAIL + 1)); echo "FAIL hooks.json is missing — no hook will ever fire when installed"
fi

if jq -e '.hooks.PreToolUse and .hooks.PostToolUse and .hooks.Stop' "$MANIFEST" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "ok   hooks.json registers PreToolUse, PostToolUse and Stop"
else
  FAIL=$((FAIL + 1)); echo "FAIL hooks.json does not register all three events"
fi

if jq -e '.hooks.PreToolUse[0].matcher | test("Write") and test("Edit")' "$MANIFEST" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "ok   the scope guard matches both Write and Edit"
else
  FAIL=$((FAIL + 1)); echo "FAIL the scope guard matcher misses Write or Edit"
fi

# Every registered script must exist and be executable.
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  rel=$(printf '%s' "$cmd" | sed 's|.*/hooks/|hooks/|')
  target="${HERE}/../../${rel}"
  if [[ -x "$target" ]]; then
    PASS=$((PASS + 1)); echo "ok   ${rel} exists and is executable"
  else
    FAIL=$((FAIL + 1)); echo "FAIL ${rel} is registered but missing or not executable"
  fi
done <<< "$(jq -r '.hooks[][].hooks[].command' "$MANIFEST" 2>/dev/null)"

if jq -r '.hooks[][].hooks[].command' "$MANIFEST" 2>/dev/null | grep -q 'CLAUDE_PLUGIN_ROOT'; then
  PASS=$((PASS + 1)); echo "ok   registered commands resolve via CLAUDE_PLUGIN_ROOT"
else
  FAIL=$((FAIL + 1)); echo "FAIL registered commands use a path that will not resolve when installed"
fi

# --- component name collisions ----------------------------------------------
# A command and a skill sharing a name resolve to the same slash invocation,
# and which one wins is not documented.
collision=0
for c in "${HERE}"/../../commands/*.md; do
  [[ -e "$c" ]] || continue
  stem=$(basename "$c" .md)
  if [[ -d "${HERE}/../../skills/${stem}" ]]; then
    echo "FAIL commands/${stem}.md collides with skills/${stem}/"
    collision=1
  fi
done
if (( collision == 0 )); then
  PASS=$((PASS + 1)); echo "ok   no command and skill share a name"
else
  FAIL=$((FAIL + 1))
fi

echo
echo "hooks: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
