#!/usr/bin/env bash
# check-scope.sh — verify each task branch stayed inside its declared fileScope.
#
# WHY THIS EXISTS.
#
# hooks/pre-tool-use-scope-guard.sh enforces file ownership at write time, which
# is the right place — it stops the write before it happens. But that hook only
# fires when the plugin is installed and the agent runs under Claude Code's hook
# machinery. An orchestrator that dispatches agents another way gets no
# enforcement at all, and file ownership is the guarantee the whole design rests
# on. This is the post-hoc check for that case: compare what each branch
# actually changed against what its task was allowed to touch.
#
# It uses the same segment-bounded glob semantics as the hook — `*` and `?` stay
# inside one path segment, `**` crosses directories — so a pass here means a
# pass there. If the two ever diverge, the authoring check passes work the
# runtime check would block.
#
# ON BASE COMMITS. Each task's base is read from `baseCommit` in the task graph.
# It cannot be inferred from history: a later wave forks from the previous
# wave's integration commit, and diffing every branch against the run's base
# branch attributes all of the earlier waves' files to the later ones. The
# orchestrator knows the base when it creates the worktree, so it records it.
#
# Usage: check-scope.sh [repo] [task-graph.json]
#   exit 0  every branch stayed in scope
#   exit 1  at least one violation
#   exit 2  usage error
#
# bash 3.2 compatible.
set -uo pipefail

REPO="${1:-$(pwd)}"
GRAPH="${2:-${REPO}/.swarm/task-graph.json}"

if [[ ! -d "$REPO/.git" ]] && ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: not a git repository: $REPO" >&2
  exit 2
fi
if [[ ! -f "$GRAPH" ]]; then
  echo "ERROR: task graph not found: $GRAPH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

RUN=$(jq -r '.runId // empty' "$GRAPH")
if [[ -z "$RUN" ]]; then
  echo "ERROR: task graph has no runId" >&2
  exit 2
fi

# Same translation as the scope-guard hook. Kept in step with it deliberately.
scope_to_regex() {
  printf '%s' "$1" | awk '{
    out = "^"; i = 1; n = length($0)
    while (i <= n) {
      c = substr($0, i, 1)
      if (c == "*") {
        if (substr($0, i + 1, 1) == "*") { out = out ".*"; i += 2 }
        else                             { out = out "[^/]*"; i += 1 }
      } else if (c == "?") { out = out "[^/]"; i += 1 }
      else if (index(".+^$()[]{}|\\", c) > 0) { out = out "\\" c; i += 1 }
      else { out = out c; i += 1 }
    }
    print out "$"
  }'
}

claims() {
  local scope="$1" path="$2"
  [[ "$scope" == "$path" ]] && return 0
  [[ "$scope" == */ && "$path" == "$scope"* ]] && return 0
  printf '%s' "$path" | grep -qE "$(scope_to_regex "$scope")" && return 0
  return 1
}

VIOLATIONS=0
EXAMINED=0

for task in $(jq -r '.waves[].tasks[].taskId' "$GRAPH"); do
  branch="swarm/${RUN}/${task}"

  if ! git -C "$REPO" rev-parse --verify --quiet "$branch" >/dev/null; then
    echo "SKIP  ${task}: branch ${branch} does not exist"
    continue
  fi

  base=$(jq -r --arg t "$task" '.waves[].tasks[] | select(.taskId==$t) | .baseCommit // empty' "$GRAPH")
  if [[ -z "$base" ]]; then
    echo "SKIP  ${task}: no baseCommit recorded — cannot verify scope without it"
    continue
  fi

  changed=$(git -C "$REPO" diff --name-only "${base}...${branch}" 2>/dev/null)
  if [[ -z "$changed" ]]; then
    echo "WARN  ${task}: branch exists but changed no files"
    continue
  fi

  scopes=$(jq -r --arg t "$task" '.waves[].tasks[] | select(.taskId==$t) | .fileScope[]' "$GRAPH")
  task_bad=0
  in_scope=0

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # .swarm/ is orchestrator state, not Drone output.
    case "$f" in .swarm/*) continue ;; esac
    EXAMINED=$((EXAMINED + 1))

    matched=0
    while IFS= read -r scope; do
      [[ -z "$scope" ]] && continue
      if claims "$scope" "$f"; then matched=1; break; fi
    done <<< "$scopes"

    if (( matched == 0 )); then
      echo "VIOLATION ${task}: wrote '${f}', outside its declared scope"
      VIOLATIONS=$((VIOLATIONS + 1))
      task_bad=1
    else
      in_scope=$((in_scope + 1))
    fi
  done <<< "$changed"

  if (( task_bad == 0 )); then
    echo "ok    ${task}: ${in_scope} file(s), all in scope"
  fi
done

echo
echo "scope check: ${EXAMINED} file(s) examined, ${VIOLATIONS} violation(s)"
[[ $VIOLATIONS -eq 0 ]]
