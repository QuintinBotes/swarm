#!/usr/bin/env bash
# run.sh — wave-level resume tests.
#
# resume-state.sh's whole job is cross-checking recorded completion against
# git reality, so these build real temporary git repositories with real
# task-graph.json files and real branches — a fixture that never touches git
# would miss exactly the failure mode (a lying resume state) this exists to
# catch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS="${HERE}/../../lib/resume-state.sh"
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

check_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $name"
    echo "       expected: $expected"
    echo "       actual:   $actual"
  fi
}

new_repo() {
  local dir="$1"
  mkdir -p "$dir/.swarm"
  (
    cd "$dir" &&
    git init -q &&
    git config user.email "swarm-test@example.com" &&
    git config user.name "Swarm Test" &&
    git commit -q --allow-empty -m init
  )
}

run_rs() {
  local dir="$1"; shift
  (cd "$dir" && bash "$RS" "$@")
}

# --- fresh repo, no state ----------------------------------------------------

REPO_A="$TMP/fresh"
new_repo "$REPO_A"
cat > "$REPO_A/.swarm/task-graph.json" <<'JSON'
{
  "runId": "2026-01-01T00-00-00_fresh",
  "specSource": "inline",
  "waves": [
    { "wave": 1, "tasks": [
      { "taskId": "T1", "title": "a", "description": "d", "fileScope": ["a"], "verificationCriteria": ["x"], "dependsOn": [] }
    ]},
    { "wave": 2, "tasks": [
      { "taskId": "T2", "title": "b", "description": "d", "fileScope": ["b"], "verificationCriteria": ["x"], "dependsOn": ["T1"] }
    ]}
  ]
}
JSON

check_eq "fresh repo: next-wave is 1" "1" "$(run_rs "$REPO_A" next-wave)"
out=$(run_rs "$REPO_A" status); code=$?
check_eq "fresh repo: status exits 0" "0" "$code"
check "fresh repo: status reports next wave 1" '"nextWave":1' "$out"
check "fresh repo: no task is claimed complete" '"status":"not-started"' "$out"

# --- multi-wave repo: recording, per-wave/task reporting, inconsistency, clear

REPO_B="$TMP/main"
new_repo "$REPO_B"
RUN_ID_B="2026-01-01T00-00-00_main"
cat > "$REPO_B/.swarm/task-graph.json" <<JSON
{
  "runId": "${RUN_ID_B}",
  "specSource": "inline",
  "waves": [
    { "wave": 1, "tasks": [
      { "taskId": "T1", "title": "a", "description": "d", "fileScope": ["a"], "verificationCriteria": ["x"], "dependsOn": [] },
      { "taskId": "T2", "title": "b", "description": "d", "fileScope": ["b"], "verificationCriteria": ["x"], "dependsOn": [] }
    ]},
    { "wave": 2, "tasks": [
      { "taskId": "T3", "title": "c", "description": "d", "fileScope": ["c"], "verificationCriteria": ["x"], "dependsOn": ["T1","T2"] }
    ]},
    { "wave": 3, "tasks": [
      { "taskId": "T4", "title": "e", "description": "d", "fileScope": ["e"], "verificationCriteria": ["x"], "dependsOn": ["T3"] }
    ]}
  ]
}
JSON

for t in T1 T2 T3; do
  (cd "$REPO_B" && git branch "swarm/${RUN_ID_B}/${t}" >/dev/null 2>&1)
done

rw_out=$(run_rs "$REPO_B" record-wave 1)
check "record-wave: confirms on stdout" "wave 1" "$rw_out"
run_rs "$REPO_B" record-wave 2 >/dev/null

check_eq "after recording waves 1+2: next-wave is 3" "3" "$(run_rs "$REPO_B" next-wave)"

status_out=$(run_rs "$REPO_B" status)
check "status: wave 1 complete"      '"wave":1,"status":"complete"'     "$status_out"
check "status: wave 2 complete"      '"wave":2,"status":"complete"'     "$status_out"
check "status: wave 3 not started"   '"wave":3,"status":"not-started"'  "$status_out"
check "status: T1 reported complete" '"taskId":"T1","status":"complete"' "$status_out"
check "status: branch name surfaced" "swarm/${RUN_ID_B}/T1"             "$status_out"
check "status: still consistent"     '"consistent":true'                "$status_out"

# A wave recorded complete whose task branch has since vanished must be
# reported as inconsistent, not trusted.
(cd "$REPO_B" && git branch -D "swarm/${RUN_ID_B}/T1" >/dev/null 2>&1)

status_out2=$(run_rs "$REPO_B" status); code2=$?
check "inconsistent: wave 1 flagged inconsistent" '"wave":1,"status":"inconsistent"'     "$status_out2"
check "inconsistent: T1 flagged inconsistent"     '"taskId":"T1","status":"inconsistent"' "$status_out2"
check "inconsistent: consistent flag is false"    '"consistent":false'                    "$status_out2"
check_eq "inconsistent: status exits non-zero"    "1" "$code2"

# clear discards the recorded state; branches on disk are not enough on their
# own to call anything complete once nothing has recorded it.
clear_out=$(run_rs "$REPO_B" clear)
check "clear: reports it cleared state" "cleared" "$clear_out"
check_eq "clear: next-wave returns to 1" "1" "$(run_rs "$REPO_B" next-wave)"
if [[ -d "$REPO_B/.swarm/resume" ]]; then
  FAIL=$((FAIL + 1)); echo "FAIL clear: resume dir removed"
else
  PASS=$((PASS + 1)); echo "ok   clear: resume dir removed"
fi

# --- partial wave completion --------------------------------------------------

REPO_C="$TMP/partial"
new_repo "$REPO_C"
RUN_ID_C="2026-01-01T00-00-00_partial"
cat > "$REPO_C/.swarm/task-graph.json" <<JSON
{
  "runId": "${RUN_ID_C}",
  "specSource": "inline",
  "waves": [
    { "wave": 1, "tasks": [
      { "taskId": "T1", "title": "a", "description": "d", "fileScope": ["a"], "verificationCriteria": ["x"], "dependsOn": [] },
      { "taskId": "T2", "title": "b", "description": "d", "fileScope": ["b"], "verificationCriteria": ["x"], "dependsOn": [] }
    ]}
  ]
}
JSON
(cd "$REPO_C" && git branch "swarm/${RUN_ID_C}/T1" >/dev/null 2>&1)
run_rs "$REPO_C" record-task T1 >/dev/null

status_c=$(run_rs "$REPO_C" status)
check "partial: wave reported partial"                 '"wave":1,"status":"partial"' "$status_c"
check "partial: done task reported complete"            '"taskId":"T1","status":"complete"' "$status_c"
check "partial: untouched task reported not-started"    '"taskId":"T2","status":"not-started"' "$status_c"
check_eq "partial: next-wave still points at that wave" "1" "$(run_rs "$REPO_C" next-wave)"

# --- malformed / missing task-graph.json does not crash -----------------------

REPO_D="$TMP/malformed"
new_repo "$REPO_D"
printf 'not json at all' > "$REPO_D/.swarm/task-graph.json"

out_d=$(run_rs "$REPO_D" status); code_d=$?
check_eq "malformed graph: status does not crash" "0" "$code_d"
check "malformed graph: status still emits JSON"  '"nextWave"' "$out_d"
check_eq "malformed graph: next-wave falls back to 1" "1" "$(run_rs "$REPO_D" next-wave)"

rm -f "$REPO_D/.swarm/task-graph.json"
out_e=$(run_rs "$REPO_D" status); code_e=$?
check_eq "missing graph: status does not crash" "0" "$code_e"
check_eq "missing graph: next-wave falls back to 1" "1" "$(run_rs "$REPO_D" next-wave)"

# --- input validation on record-wave / record-task ----------------------------

out_f=$(run_rs "$REPO_D" record-wave abc); code_f=$?
check_eq "record-wave rejects a non-integer" "1" "$code_f"
check "record-wave explains why on stdout" "positive integer" "$out_f"

out_g=$(run_rs "$REPO_D" record-task nope); code_g=$?
check_eq "record-task rejects a malformed id" "1" "$code_g"

echo
echo "resume: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
