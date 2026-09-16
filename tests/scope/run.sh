#!/usr/bin/env bash
# run.sh — tests for the post-hoc scope checker.
#
# The checker must agree exactly with hooks/pre-tool-use-scope-guard.sh. A
# divergence means work that passes verification would have been blocked at
# runtime, or worse, the reverse.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${HERE}/../../lib/check-scope.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

expect() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name — expected '$want', got '$got'"; fi
}
contains() {
  local name="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name — output lacked '$needle'"; fi
}

R="$TMP/repo"
mkdir -p "$R/src" "$R/tests"
git -C "$R" init -q 2>/dev/null || (cd "$R" && git init -q)
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
mkdir -p "$R/.swarm"
# .swarm/ is orchestrator state and is gitignored in a real run. Without this
# the harness's own `git add -A` commits the task graph, and checking out the
# base commit then deletes it.
echo '.swarm/' > "$R/.gitignore"
echo base > "$R/src/base.txt"
git -C "$R" add -A
git -C "$R" commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

write_graph() {
  cat > "$R/.swarm/task-graph.json" <<JSON
{
  "runId": "testrun",
  "specSource": "inline",
  "waves": [
    { "wave": 1, "tasks": [
      { "taskId": "T1", "title": "t", "description": "d",
        "fileScope": ["src/one.txt", "tests/t1/*.txt"],
        "verificationCriteria": ["c"], "dependsOn": [], "baseCommit": "${BASE}" },
      { "taskId": "T2", "title": "t", "description": "d",
        "fileScope": ["src/two.txt"],
        "verificationCriteria": ["c"], "dependsOn": [], "baseCommit": "${BASE}" }
    ]}
  ]
}
JSON
}
write_graph

commit_on() {
  local branch="$1"; shift
  git -C "$R" checkout -q -B "$branch" "$BASE"
  for f in "$@"; do
    mkdir -p "$R/$(dirname "$f")"
    echo x > "$R/$f"
  done
  git -C "$R" add -A
  git -C "$R" commit -qm "work on $branch"
}

# --- in scope ---------------------------------------------------------------
commit_on swarm/testrun/T1 src/one.txt
commit_on swarm/testrun/T2 src/two.txt
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1); rc=$?
expect "two compliant branches pass" "0" "$rc"
contains "reports each task as ok" "$out" "ok    T1"

# --- out of scope -----------------------------------------------------------
commit_on swarm/testrun/T2 src/two.txt src/sneaky.txt
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1); rc=$?
expect "a write outside scope fails" "1" "$rc"
contains "names the offending file" "$out" "src/sneaky.txt"
contains "names the offending task"  "$out" "T2"

# --- writing another task's file --------------------------------------------
commit_on swarm/testrun/T2 src/two.txt src/one.txt
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1); rc=$?
expect "writing another task's file fails" "1" "$rc"

# --- glob semantics must match the hook -------------------------------------
commit_on swarm/testrun/T2 src/two.txt
commit_on swarm/testrun/T1 tests/t1/a.txt
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1); rc=$?
expect "a glob match inside one segment passes" "0" "$rc"

commit_on swarm/testrun/T1 tests/t1/deep/b.txt
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1); rc=$?
expect "a glob must not cross a directory boundary" "1" "$rc"

# --- orchestrator state is not Drone output ---------------------------------
git -C "$R" checkout -q -B swarm/testrun/T1 "$BASE"
echo x > "$R/src/one.txt"
mkdir -p "$R/.swarm/qa-status" && echo y > "$R/.swarm/qa-status/T1.passed"
git -C "$R" add -A
# Force-add only the state file, not the whole of .swarm/ — adding the task
# graph itself would delete it on the next checkout of the base commit.
git -C "$R" add -f .swarm/qa-status/T1.passed 2>/dev/null || \
  (cd "$R" && git add -f .swarm/qa-status/T1.passed)
git -C "$R" commit -qm "work plus swarm state"
commit_on swarm/testrun/T2 src/two.txt
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1); rc=$?
expect ".swarm state is not counted as a violation" "0" "$rc"

# --- later waves fork from a different base ---------------------------------
# This is the case that produced a false positive before baseCommit was
# recorded: diffing a wave-2 branch against the run base attributes every
# wave-1 file to it.
git -C "$R" checkout -q -B integration "$BASE"
git -C "$R" merge -q --no-ff swarm/testrun/T1 -m m1
git -C "$R" merge -q --no-ff swarm/testrun/T2 -m m2
W2BASE=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -B swarm/testrun/T3 "$W2BASE"
echo x > "$R/docs.md"
git -C "$R" add -A && git -C "$R" commit -qm "wave 2 work"
python3 - "$R/.swarm/task-graph.json" "$W2BASE" <<'PY'
import json,sys
p,w2=sys.argv[1],sys.argv[2]
d=json.load(open(p))
d["waves"].append({"wave":2,"tasks":[{"taskId":"T3","title":"t","description":"d",
  "fileScope":["docs.md"],"verificationCriteria":["c"],"dependsOn":["T1","T2"],"baseCommit":w2}]})
json.dump(d,open(p,'w'),indent=2)
PY
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1); rc=$?
expect "a wave-2 branch is judged against its own base" "0" "$rc"
contains "wave 2 reports only its own file" "$out" "ok    T3: 1 file(s)"

# --- refuses to guess -------------------------------------------------------
python3 - "$R/.swarm/task-graph.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for w in d["waves"]:
    for t in w["tasks"]:
        if t["taskId"]=="T3": t.pop("baseCommit",None)
json.dump(d,open(p,'w'),indent=2)
PY
out=$(bash "$CHECK" "$R" "$R/.swarm/task-graph.json" 2>&1)
contains "a task with no baseCommit is skipped, not guessed" "$out" "no baseCommit recorded"

# --- usage errors -----------------------------------------------------------
bash "$CHECK" "$TMP/nope" "$R/.swarm/task-graph.json" >/dev/null 2>&1
expect "a non-repository is a usage error" "2" "$?"
bash "$CHECK" "$R" "$TMP/missing.json" >/dev/null 2>&1
expect "a missing task graph is a usage error" "2" "$?"

echo
echo "scope: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
