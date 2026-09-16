#!/bin/bash
# hooks/pre-tool-use-scope-guard.sh
# PreToolUse hook: blocks Implementor writes outside declared file scope.
# Reads Claude Code hook JSON from stdin.
# Exits 0 to allow, exits 2 to block.
#
# The block reason goes to STDERR, not stdout. Claude Code reads a blocking
# hook's feedback from stderr; a reason written to stdout is silently dropped,
# so the write is refused with no explanation of why. That is worse than not
# blocking at all, because the agent cannot act on it.

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract tool name and file path from the hook payload
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only gate Write and Edit tools
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

# No file path means nothing to gate
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Find the .swarm directory — walk up from cwd
SWARM_DIR=""
DIR="$(pwd)"
while [[ "$DIR" != "/" ]]; do
  if [[ -f "$DIR/.swarm/task-graph.json" ]]; then
    SWARM_DIR="$DIR/.swarm"
    break
  fi
  DIR=$(dirname "$DIR")
done

# No active swarm — allow everything (not in a swarm run)
if [[ -z "$SWARM_DIR" ]]; then
  exit 0
fi

# Read the task ID for this worktree
TASK_ID_FILE="$SWARM_DIR/current-task-id"
if [[ ! -f "$TASK_ID_FILE" ]]; then
  # No task ID file means this isn't an Implementor worktree — allow
  exit 0
fi

TASK_ID=$(cat "$TASK_ID_FILE")
TASK_GRAPH="$SWARM_DIR/task-graph.json"

# Extract file scope for this task from task-graph.json
FILE_SCOPES=$(jq -r --arg tid "$TASK_ID" '
  .waves[].tasks[] | select(.taskId == $tid) | .fileScope[]
' "$TASK_GRAPH" 2>/dev/null)

if [[ -z "$FILE_SCOPES" ]]; then
  echo "BLOCKED: Could not find fileScope for task $TASK_ID in task-graph.json" >&2
  exit 2
fi

# Resolve FILE_PATH to a normalised path relative to the repo root.
REPO_ROOT="$DIR"
ABS_PATH="$FILE_PATH"
[[ "$ABS_PATH" != /* ]] && ABS_PATH="${REPO_ROOT}/${ABS_PATH}"

# Collapse . and .. so a traversal cannot be laundered past the scope check.
NORM_PATH=$(cd "$(dirname "$ABS_PATH")" 2>/dev/null && pwd -P)/$(basename "$ABS_PATH")
if [[ "$NORM_PATH" == "/$(basename "$ABS_PATH")" ]]; then
  # dirname did not resolve — the parent does not exist yet, which is normal for
  # a new file. Fall back to lexical normalisation.
  NORM_PATH=$(printf '%s' "$ABS_PATH" | awk -F/ '{
    n=0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n > 0) n--; continue }
      out[++n] = $i
    }
    s = ""
    for (i = 1; i <= n; i++) s = s "/" out[i]
    print s
  }')
fi

# Anything outside the repo root is out of scope by definition.
case "$NORM_PATH" in
  "$REPO_ROOT"/*) REL_PATH="${NORM_PATH#$REPO_ROOT/}" ;;
  *)
    echo "BLOCKED: '$FILE_PATH' resolves outside the repository root." >&2
    exit 2
    ;;
esac

# Translate a scope pattern into an anchored regex.
#
# Bash's own `==` glob lets `*` match across `/`, so `src/api/*.ts` would match
# `src/api/deep/nested.ts`. That quietly widens every task's territory and can
# make two scopes that look disjoint overlap at runtime — which is precisely the
# failure this hook exists to prevent. So `*` is bounded to one path segment,
# and `**` is the only way to cross a directory boundary.
scope_to_regex() {
  printf '%s' "$1" | awk '{
    out = "^"
    i = 1
    n = length($0)
    while (i <= n) {
      c = substr($0, i, 1)
      if (c == "*") {
        if (substr($0, i + 1, 1) == "*") { out = out ".*"; i += 2 }
        else                             { out = out "[^/]*"; i += 1 }
      } else if (c == "?") {
        out = out "[^/]"; i += 1
      } else if (index(".+^$()[]{}|\\", c) > 0) {
        out = out "\\" c; i += 1
      } else {
        out = out c; i += 1
      }
    }
    print out "$"
  }'
}

MATCHED=false
while IFS= read -r scope; do
  [[ -z "$scope" ]] && continue

  # Exact path.
  if [[ "$REL_PATH" == "$scope" ]]; then
    MATCHED=true
    break
  fi

  # Directory scope: a trailing slash claims anything created beneath it.
  if [[ "$scope" == */ && "$REL_PATH" == "$scope"* ]]; then
    MATCHED=true
    break
  fi

  # Segment-aware glob.
  if printf '%s' "$REL_PATH" | grep -qE "$(scope_to_regex "$scope")"; then
    MATCHED=true
    break
  fi
done <<< "$FILE_SCOPES"

if [[ "$MATCHED" == "false" ]]; then
  {
    echo "BLOCKED: File '$REL_PATH' is outside task $TASK_ID's declared scope."
    echo ""
    echo "Allowed files for $TASK_ID:"
    echo "$FILE_SCOPES" | sed 's/^/  - /'
    echo ""
    echo "If you need to modify this file, report it in your completion summary."
  } >&2
  exit 2
fi

exit 0
