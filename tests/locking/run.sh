#!/usr/bin/env bash
# run.sh — run-lock.sh tests.
# Two concurrent swarm runs share .swarm/task-graph.json, .swarm/current-
# task-id, and .swarm/qa-status/ in the same repo. These tests exercise the
# real lock script against real temporary "repos" (SWARM_ROOT overrides),
# never a mock.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${HERE}/../../lib/run-lock.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run-lock.sh records $PPID as the holder by default, but every call below
# goes through `$(...)` command substitution, which forks a throwaway
# subshell as that immediate parent — one that is reaped the instant the
# substitution finishes. Pin a pid that actually lives for this whole test
# run instead, exactly as the script's header comment tells real callers to.
export RUN_LOCK_PID="$$"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
FAIL_() { FAIL=$((FAIL + 1)); echo "FAIL $1"; shift; for line in "$@"; do echo "       $line"; done; }

# A fresh, empty repo directory for one test's SWARM_ROOT.
fresh_repo() {
  local dir="$TMP/repo-$RANDOM-$RANDOM"
  mkdir -p "$dir"
  echo "$dir"
}

# Runs run-lock.sh against $1 (repo root) with args $2... . Sets globals
# OUT and CODE rather than echoing, so callers can inspect both.
run_lock() {
  local repo="$1"; shift
  OUT="$(SWARM_ROOT="$repo" bash "$LOCK" "$@" 2>&1)"
  CODE=$?
}

# Produces a pid that is guaranteed dead: fork a no-op child, wait for it to
# exit and be reaped, then hand back its pid. `kill -0` on a reaped pid fails
# with ESRCH, which is exactly the "no longer exists" case status/reclaim
# must detect. This is more honest than picking a large constant, which some
# system could legitimately be using.
dead_pid() {
  ( exit 0 ) &
  local p=$!
  wait "$p" 2>/dev/null
  echo "$p"
}

# Overwrites the recorded holder pid in a repo's lock info file, keeping the
# other fields as they are. Used to simulate "the holding process crashed."
set_lock_pid() {
  local repo="$1" new_pid="$2"
  local info="$repo/.swarm/lock/info"
  local run_id started_at
  run_id="$(grep -m1 '^run_id=' "$info" | cut -d= -f2-)"
  started_at="$(grep -m1 '^started_at=' "$info" | cut -d= -f2-)"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'pid=%s\n' "$new_pid"
    printf 'started_at=%s\n' "$started_at"
  } > "$info"
}

# --- acquire on a clean repo -------------------------------------------------
repo="$(fresh_repo)"
run_lock "$repo" acquire run-a
if [[ $CODE -eq 0 ]] && [[ "$OUT" == *"run-a"* ]] && [[ -d "$repo/.swarm/lock" ]]; then
  ok "acquire on a clean repo succeeds"
else
  FAIL_ "acquire on a clean repo succeeds" "exit=$CODE" "out: $OUT"
fi

# --- a second acquire with a different run id fails, naming the holder ------
run_lock "$repo" acquire run-b
if [[ $CODE -ne 0 ]] && [[ "$OUT" == *"run-a"* ]]; then
  ok "second acquire with a different run id fails and names the holder"
else
  FAIL_ "second acquire with a different run id fails and names the holder" "exit=$CODE" "out: $OUT"
fi

# --- release by the holder succeeds; lock is then acquirable again ---------
run_lock "$repo" release run-a
rel_code=$CODE
run_lock "$repo" acquire run-c
if [[ $rel_code -eq 0 ]] && [[ $CODE -eq 0 ]] && [[ "$OUT" == *"run-c"* ]]; then
  ok "release by the holder succeeds and the lock is acquirable again"
else
  FAIL_ "release by the holder succeeds and the lock is acquirable again" "release exit=$rel_code" "acquire exit=$CODE" "out: $OUT"
fi

# --- release by a non-holder fails; the lock survives ------------------------
run_lock "$repo" release run-nope
rel_code=$CODE
rel_out="$OUT"
run_lock "$repo" status
if [[ $rel_code -ne 0 ]] && [[ "$rel_out" == *"run-nope"* || "$rel_out" == *"run-c"* ]] && [[ "$OUT" == *"run-c"* ]]; then
  ok "release by a non-holder fails and the lock survives"
else
  FAIL_ "release by a non-holder fails and the lock survives" "release exit=$rel_code" "release out: $rel_out" "status out: $OUT"
fi

# --- status on an unlocked repo reports no holder, and does not error ------
repo2="$(fresh_repo)"
run_lock "$repo2" status
if [[ $CODE -eq 0 ]] && [[ "$OUT" == *"no lock"* ]]; then
  ok "status on an unlocked repo reports no holder without erroring"
else
  FAIL_ "status on an unlocked repo reports no holder without erroring" "exit=$CODE" "out: $OUT"
fi

# --- a lock whose recorded pid is dead is reported stale by status ---------
repo3="$(fresh_repo)"
run_lock "$repo3" acquire run-d
dp="$(dead_pid)"
set_lock_pid "$repo3" "$dp"
run_lock "$repo3" status
if [[ $CODE -eq 0 ]] && [[ "$OUT" == *"STALE"* ]] && [[ "$OUT" == *"run-d"* ]]; then
  ok "a lock whose recorded pid is dead is reported stale by status"
else
  FAIL_ "a lock whose recorded pid is dead is reported stale by status" "exit=$CODE" "out: $OUT"
fi

# --- reclaim takes over a stale lock and reports that it was stale ---------
run_lock "$repo3" reclaim run-e
if [[ $CODE -eq 0 ]] && [[ "$OUT" == *"stale"* ]] && [[ "$OUT" == *"run-d"* ]] && [[ "$OUT" == *"run-e"* ]]; then
  ok "reclaim takes over a stale lock and reports that it was stale"
else
  FAIL_ "reclaim takes over a stale lock and reports that it was stale" "exit=$CODE" "out: $OUT"
fi
run_lock "$repo3" status
if [[ "$OUT" == *"run-e"* ]] && [[ "$OUT" == *"live"* ]]; then
  ok "after reclaim the lock is held by the new run and is live"
else
  FAIL_ "after reclaim the lock is held by the new run and is live" "out: $OUT"
fi

# --- reclaim does NOT take over a live lock ---------------------------------
repo4="$(fresh_repo)"
run_lock "$repo4" acquire run-f
run_lock "$repo4" reclaim run-g
reclaim_code=$CODE
reclaim_out="$OUT"
run_lock "$repo4" status
if [[ $reclaim_code -ne 0 ]] && [[ "$reclaim_out" == *"run-f"* ]] && [[ "$OUT" == *"run-f"* ]] && [[ "$OUT" == *"live"* ]]; then
  ok "reclaim does not take over a live lock"
else
  FAIL_ "reclaim does not take over a live lock" "reclaim exit=$reclaim_code" "reclaim out: $reclaim_out" "status out: $OUT"
fi

# --- re-acquire by the SAME run id is a documented no-op success -----------
repo5="$(fresh_repo)"
run_lock "$repo5" acquire run-h
first_code=$CODE
run_lock "$repo5" acquire run-h
if [[ $first_code -eq 0 ]] && [[ $CODE -eq 0 ]] && [[ "$OUT" == *"run-h"* ]]; then
  ok "re-acquiring with the same run id is a no-op success"
else
  FAIL_ "re-acquiring with the same run id is a no-op success" "first exit=$first_code" "second exit=$CODE" "out: $OUT"
fi
# It must still be the sole holder, not duplicated or corrupted.
run_lock "$repo5" release run-other
if [[ $CODE -ne 0 ]]; then
  ok "the lock is still exclusively held after a same-run re-acquire"
else
  FAIL_ "the lock is still exclusively held after a same-run re-acquire" "exit=$CODE" "out: $OUT"
fi

echo
echo "locking: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
