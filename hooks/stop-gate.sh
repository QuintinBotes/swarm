#!/bin/bash
# hooks/stop-gate.sh
# Stop hook: holds the turn open while a task has unverified writes.
#
# Two things this has to get right, both easy to get wrong:
#
# 1. The reason goes to STDERR. Claude Code reads a blocking hook's feedback
#    from stderr; a reason on stdout is discarded, so the turn is held open with
#    no explanation of what to do about it.
#
# 2. It must stand down when the runtime says it has already blocked. The
#    payload carries `stop_hook_active`, which is true when this hook already
#    blocked the current turn. Without checking it, a QA state that can never be
#    satisfied blocks forever, until the runtime's consecutive-block cap
#    intervenes. A gate that cannot be satisfied must yield rather than trap the
#    session.
#
# Exit 0 to allow the turn to end, exit 2 to hold it open.

set -uo pipefail

# The payload may be absent when this is invoked by hand or under test.
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT=$(cat 2>/dev/null || true)
fi

# Already blocked once this turn — yield rather than loop.
if [[ -n "$INPUT" ]] && command -v jq >/dev/null 2>&1; then
  ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
  if [[ "$ACTIVE" == "true" ]]; then
    exit 0
  fi
fi

# Find the .swarm directory by walking up from the working directory.
SWARM_DIR=""
DIR="$(pwd)"
while [[ "$DIR" != "/" ]]; do
  if [[ -d "$DIR/.swarm" ]]; then
    SWARM_DIR="$DIR/.swarm"
    break
  fi
  DIR=$(dirname "$DIR")
done

# No active run: this hook has nothing to say.
[[ -z "$SWARM_DIR" ]] && exit 0

TASK_ID_FILE="$SWARM_DIR/current-task-id"
[[ -f "$TASK_ID_FILE" ]] || exit 0

TASK_ID=$(cat "$TASK_ID_FILE")
QA_DIR="$SWARM_DIR/qa-status"

if [[ -f "$QA_DIR/${TASK_ID}.pending" && ! -f "$QA_DIR/${TASK_ID}.passed" ]]; then
  {
    echo "BLOCKED: QA has not passed for task $TASK_ID."
    echo ""
    echo "Files were modified but no verification has confirmed they pass."
    echo "Run the verification criteria before finishing:"

    TASK_GRAPH="$SWARM_DIR/task-graph.json"
    if [[ -f "$TASK_GRAPH" ]] && command -v jq >/dev/null 2>&1; then
      jq -r --arg tid "$TASK_ID" '
        .waves[].tasks[] | select(.taskId == $tid) | .verificationCriteria[] | "  - " + .
      ' "$TASK_GRAPH" 2>/dev/null
    fi
  } >&2
  exit 2
fi

exit 0
