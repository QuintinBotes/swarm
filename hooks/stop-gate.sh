#!/bin/bash
# hooks/stop-gate.sh
# Stop hook: blocks session end if QA is pending and not passed.

set -euo pipefail

# Find .swarm directory
SWARM_DIR=""
DIR="$(pwd)"
while [[ "$DIR" != "/" ]]; do
  if [[ -d "$DIR/.swarm" ]]; then
    SWARM_DIR="$DIR/.swarm"
    break
  fi
  DIR=$(dirname "$DIR")
done

if [[ -z "$SWARM_DIR" ]]; then
  exit 0
fi

TASK_ID_FILE="$SWARM_DIR/current-task-id"
if [[ ! -f "$TASK_ID_FILE" ]]; then
  exit 0
fi

TASK_ID=$(cat "$TASK_ID_FILE")
QA_DIR="$SWARM_DIR/qa-status"

# Check if QA is pending but not passed
if [[ -f "$QA_DIR/${TASK_ID}.pending" && ! -f "$QA_DIR/${TASK_ID}.passed" ]]; then
  echo "BLOCKED: QA has not passed for task $TASK_ID."
  echo ""
  echo "You have modified files but QA validation has not confirmed they pass."
  echo "Run your verification criteria before completing:"

  # Show the verification criteria from task-graph
  TASK_GRAPH="$SWARM_DIR/task-graph.json"
  if [[ -f "$TASK_GRAPH" ]]; then
    jq -r --arg tid "$TASK_ID" '
      .waves[].tasks[] | select(.taskId == $tid) | .verificationCriteria[] | "  - " + .
    ' "$TASK_GRAPH" 2>/dev/null
  fi

  exit 2
fi

exit 0
