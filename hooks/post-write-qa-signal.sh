#!/bin/bash
# hooks/post-write-qa-signal.sh
# PostToolUse hook: signals that a file was written and QA is pending.
# Creates a flag file so the stop-gate knows QA hasn't run yet.

set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only signal on Write and Edit
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

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

# Touch the qa-pending flag for this task
mkdir -p "$SWARM_DIR/qa-status"
touch "$SWARM_DIR/qa-status/${TASK_ID}.pending"

# Remove any previous qa-passed flag (code changed since last QA)
rm -f "$SWARM_DIR/qa-status/${TASK_ID}.passed"

exit 0
