#!/usr/bin/env bash
# run.sh — integration-check tests.
# check-integration.sh is the layer that catches a semantic conflict a merge
# cannot see: two tasks with disjoint file sets where one deletes or renames a
# symbol the other still calls. Every case here builds a real temporary git
# repo with real branches and runs the real script against it — there is no
# fixture that stands in for a git diff.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${HERE}/../../lib/check-integration.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; shift; for l in "$@"; do echo "       $l"; done; }

# A fresh, empty git repo under $TMP, on branch "main". Echoes its path.
# Uses mktemp for the unique name — a counter would not survive being
# incremented inside the `$(new_repo)` command substitution that calls it.
new_repo() {
  local dir
  dir=$(mktemp -d "$TMP/repo.XXXXXX")
  ( cd "$dir" && git init -q -b main . \
    && git config user.email "t@t.com" && git config user.name "t" )
  printf '%s' "$dir"
}

# commit_file <repo> <path> <<'EOF' ... EOF   — write, add, commit on the repo's
# current branch.
commit_file() {
  local repo="$1" path="$2" msg="${3:-update $2}"
  mkdir -p "$(dirname "$repo/$path")"
  cat > "$repo/$path"
  ( cd "$repo" && git add "$path" && git commit -q -m "$msg" )
}

branch_from() {
  local repo="$1" name="$2" from="${3:-main}"
  ( cd "$repo" && git checkout -q -b "$name" "$from" )
}

run_check() {
  local repo="$1"; shift
  ( cd "$repo" && bash "$CHECK" "$@" )
}

# --- THE CORE CASE: branch A deletes a function branch B calls -------------
R=$(new_repo)
commit_file "$R" lib.sh <<'EOF'
#!/usr/bin/env bash
foo() {
  echo "hi"
}
EOF
branch_from "$R" branchA
commit_file "$R" lib.sh "remove foo" <<'EOF'
#!/usr/bin/env bash
bar() {
  echo "hi"
}
EOF
branch_from "$R" branchB
commit_file "$R" caller.sh "call foo" <<'EOF'
#!/usr/bin/env bash
foo arg1
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 1 ]]; then ok "core case exits non-zero"
else fail "core case exits non-zero" "exit was $rc" "$out"; fi
if printf '%s' "$out" | grep -q '"symbol":"foo"'; then ok "core case names the symbol"
else fail "core case names the symbol" "$out"; fi
if printf '%s' "$out" | grep -q '"removedBy":"branchA"' && printf '%s' "$out" | grep -q '"referencedBy":"branchB"'; then
  ok "core case names both branches"
else
  fail "core case names both branches" "$out"
fi

# --- THE CORE NEGATIVE: unrelated symbols -----------------------------------
R=$(new_repo)
commit_file "$R" lib.sh <<'EOF'
#!/usr/bin/env bash
alpha() {
  echo "a"
}
beta() {
  echo "b"
}
EOF
branch_from "$R" branchA
commit_file "$R" lib.sh "remove alpha" <<'EOF'
#!/usr/bin/env bash
beta() {
  echo "b"
}
EOF
branch_from "$R" branchB
commit_file "$R" caller.sh "call beta, unrelated to alpha" <<'EOF'
#!/usr/bin/env bash
beta arg1
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 0 ]]; then ok "unrelated symbols exit 0"
else fail "unrelated symbols exit 0" "exit was $rc" "$out"; fi
if printf '%s' "$out" | grep -q '"collisions": \[\]'; then ok "unrelated symbols report no collisions"
else fail "unrelated symbols report no collisions" "$out"; fi

# --- Rename: delete old name, add new name, elsewhere still calls old name --
R=$(new_repo)
commit_file "$R" lib.sh <<'EOF'
#!/usr/bin/env bash
old_name() {
  echo "hi"
}
EOF
branch_from "$R" branchA
commit_file "$R" lib.sh "rename old_name to new_name" <<'EOF'
#!/usr/bin/env bash
new_name() {
  echo "hi"
}
EOF
branch_from "$R" branchB
commit_file "$R" caller.sh "still calls the old name" <<'EOF'
#!/usr/bin/env bash
old_name arg1
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q '"symbol":"old_name"'; then
  ok "a rename is detected as removal of the old name"
else
  fail "a rename is detected as removal of the old name" "exit=$rc" "$out"
fi

# --- Symbol moved within the SAME branch is not flagged ---------------------
R=$(new_repo)
commit_file "$R" a.sh <<'EOF'
#!/usr/bin/env bash
shared_helper() {
  echo "hi"
}
EOF
branch_from "$R" branchA
commit_file "$R" a.sh "move shared_helper out of a.sh" <<'EOF'
#!/usr/bin/env bash
echo "nothing here now"
EOF
commit_file "$R" b.sh "shared_helper now lives in b.sh" <<'EOF'
#!/usr/bin/env bash
shared_helper() {
  echo "hi"
}
EOF
branch_from "$R" branchB
commit_file "$R" caller.sh "calls the moved function" <<'EOF'
#!/usr/bin/env bash
shared_helper arg1
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q '"collisions": \[\]'; then
  ok "a symbol moved within the same branch is not flagged"
else
  fail "a symbol moved within the same branch is not flagged" "exit=$rc" "$out"
fi

# --- A removed symbol nobody references is not flagged ----------------------
R=$(new_repo)
commit_file "$R" a.sh <<'EOF'
#!/usr/bin/env bash
unused_helper() {
  echo "hi"
}
EOF
branch_from "$R" branchA
commit_file "$R" a.sh "delete unused_helper, nobody called it" <<'EOF'
#!/usr/bin/env bash
echo "nothing here now"
EOF
branch_from "$R" branchB
commit_file "$R" b.sh "unrelated change" <<'EOF'
#!/usr/bin/env bash
totally_unrelated_thing arg1
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q '"collisions": \[\]'; then
  ok "a removed symbol nobody references is not flagged"
else
  fail "a removed symbol nobody references is not flagged" "exit=$rc" "$out"
fi

# --- Generic/short identifiers are never flagged ----------------------------
R=$(new_repo)
commit_file "$R" a.sh <<'EOF'
#!/usr/bin/env bash
run() {
  echo "hi"
}
ab() {
  echo "short"
}
EOF
branch_from "$R" branchA
commit_file "$R" a.sh "remove run and ab" <<'EOF'
#!/usr/bin/env bash
echo "nothing here now"
EOF
branch_from "$R" branchB
commit_file "$R" b.sh "still calls both" <<'EOF'
#!/usr/bin/env bash
run arg1
ab arg2
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q '"collisions": \[\]'; then
  ok "generic and short identifiers are not flagged"
else
  fail "generic and short identifiers are not flagged" "exit=$rc" "$out"
fi

# --- An unsupported extension is a reported gap, never a false positive -----
R=$(new_repo)
commit_file "$R" a.sh <<'EOF'
#!/usr/bin/env bash
echo "base"
EOF
branch_from "$R" branchA
commit_file "$R" widget.vue "add an unsupported file" <<'EOF'
<template>
  <div>{{ old_name }}</div>
</template>
EOF
commit_file "$R" widget2.vue "add another unsupported file" <<'EOF'
<template>
  <div>{{ other }}</div>
</template>
EOF

out=$(run_check "$R" main branchA); rc=$?
if [[ $rc -eq 0 ]]; then ok "an unsupported extension does not fail the run"
else fail "an unsupported extension does not fail the run" "exit=$rc" "$out"; fi
if printf '%s' "$out" | grep -qE '"extension":"vue".*"files":2' || printf '%s' "$out" | grep -q '"2 files in vue were not analysed"'; then
  ok "an unsupported extension is reported as a coverage gap"
else
  fail "an unsupported extension is reported as a coverage gap" "$out"
fi

# --- More than two branches at once -----------------------------------------
R=$(new_repo)
commit_file "$R" lib.sh <<'EOF'
#!/usr/bin/env bash
target_fn() {
  echo "hi"
}
EOF
branch_from "$R" branchA
commit_file "$R" lib.sh "remove target_fn" <<'EOF'
#!/usr/bin/env bash
echo "gone"
EOF
branch_from "$R" branchB
commit_file "$R" unrelated.sh "totally unrelated work" <<'EOF'
#!/usr/bin/env bash
echo "unrelated"
EOF
branch_from "$R" branchC
commit_file "$R" caller.sh "calls target_fn" <<'EOF'
#!/usr/bin/env bash
target_fn arg1
EOF

out=$(run_check "$R" main branchA branchB branchC); rc=$?
if [[ $rc -eq 1 ]] \
  && printf '%s' "$out" | grep -q '"removedBy":"branchA"' \
  && printf '%s' "$out" | grep -q '"referencedBy":"branchC"' \
  && ! printf '%s' "$out" | grep -q '"referencedBy":"branchB"'; then
  ok "collision detection works across more than two branches"
else
  fail "collision detection works across more than two branches" "exit=$rc" "$out"
fi
if printf '%s' "$out" | grep -q '"branchesChecked": 3'; then
  ok "all three branches are reported as checked"
else
  fail "all three branches are reported as checked" "$out"
fi

# --- A branch with no changes at all does not crash it ----------------------
R=$(new_repo)
commit_file "$R" a.sh <<'EOF'
#!/usr/bin/env bash
echo "base"
EOF
branch_from "$R" branchA
branch_from "$R" branchB

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 0 ]]; then ok "a no-op branch does not crash the check"
else fail "a no-op branch does not crash the check" "exit=$rc" "$out"; fi
if printf '%s' "$out" | grep -q '"collisions": \[\]'; then
  ok "a no-op branch reports no collisions"
else
  fail "a no-op branch reports no collisions" "$out"
fi

# --- A missing base or branch is a usage error, not a crash -----------------
R=$(new_repo)
commit_file "$R" a.sh <<'EOF'
#!/usr/bin/env bash
echo "base"
EOF
out=$(run_check "$R" main does-not-exist 2>/dev/null); rc=$?
if [[ $rc -eq 2 ]]; then ok "a missing branch is a usage error (exit 2)"
else fail "a missing branch is a usage error (exit 2)" "exit=$rc" "$out"; fi

# --- Cross-language: Python def removed, called elsewhere -------------------
R=$(new_repo)
commit_file "$R" service.py <<'EOF'
def process_order(order):
    return order
EOF
branch_from "$R" branchA
commit_file "$R" service.py "remove process_order" <<'EOF'
def process_refund(order):
    return order
EOF
branch_from "$R" branchB
commit_file "$R" client.py "still calls process_order" <<'EOF'
result = process_order(payload)
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q '"symbol":"process_order"'; then
  ok "python function removal vs. call is detected"
else
  fail "python function removal vs. call is detected" "exit=$rc" "$out"
fi

# --- Cross-language: JS export const removed, called elsewhere -------------
R=$(new_repo)
commit_file "$R" utils.js <<'EOF'
export const formatPrice = (v) => v;
EOF
branch_from "$R" branchA
commit_file "$R" utils.js "remove formatPrice" <<'EOF'
export const formatDate = (v) => v;
EOF
branch_from "$R" branchB
commit_file "$R" checkout.js "still calls formatPrice" <<'EOF'
const total = formatPrice(amount);
EOF

out=$(run_check "$R" main branchA branchB); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -q '"symbol":"formatPrice"'; then
  ok "js exported const removal vs. call is detected"
else
  fail "js exported const removal vs. call is detected" "exit=$rc" "$out"
fi

# --- --task-graph mode -------------------------------------------------------
R=$(new_repo)
commit_file "$R" lib.sh <<'EOF'
#!/usr/bin/env bash
graph_fn() {
  echo "hi"
}
EOF
( cd "$R" && git checkout -q -b "swarm/2026-01-01T00-00-00_demo/T1" main )
commit_file "$R" lib.sh "remove graph_fn" <<'EOF'
#!/usr/bin/env bash
echo "gone"
EOF
( cd "$R" && git checkout -q -b "swarm/2026-01-01T00-00-00_demo/T2" main )
commit_file "$R" caller.sh "calls graph_fn" <<'EOF'
#!/usr/bin/env bash
graph_fn arg1
EOF
mkdir -p "$R/.swarm"
cat > "$R/.swarm/task-graph.json" <<'JSON'
{
  "runId": "2026-01-01T00-00-00_demo",
  "specSource": "inline",
  "baseBranch": "main",
  "waves": [
    { "wave": 1, "tasks": [
      { "taskId": "T1", "title": "Remove graph_fn", "description": "x",
        "fileScope": ["lib.sh"], "verificationCriteria": ["x"], "dependsOn": [] },
      { "taskId": "T2", "title": "Call graph_fn", "description": "x",
        "fileScope": ["caller.sh"], "verificationCriteria": ["x"], "dependsOn": [] }
    ]}
  ]
}
JSON

out=$(run_check "$R" --task-graph .swarm/task-graph.json); rc=$?
if [[ $rc -eq 1 ]] \
  && printf '%s' "$out" | grep -q '"symbol":"graph_fn"' \
  && printf '%s' "$out" | grep -q '"removedBy":"T1"' \
  && printf '%s' "$out" | grep -q '"referencedBy":"T2"'; then
  ok "--task-graph mode resolves task ids to branches and detects the collision"
else
  fail "--task-graph mode resolves task ids to branches and detects the collision" "exit=$rc" "$out"
fi

echo
echo "integration-check: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
