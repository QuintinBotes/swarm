#!/usr/bin/env bash
# resume-state.sh — Record and report wave/task completion so a swarm run can
# resume instead of restarting from wave 1.
#
# Why this exists: a run executes waves sequentially. If the orchestrator
# process dies mid-run, waves already completed are QA-verified and their
# task branches still exist in git — but nothing on disk says so. Without
# this, a re-run throws that verified work away and starts over. This script
# is the durable record: the orchestrator calls `record-wave` / `record-task`
# the instant each one finishes (never buffered, never batched at the end),
# and `status` / `next-wave` tell a fresh orchestrator process where to pick
# up.
#
# Recorded state is trusted only as far as git confirms it: `status` cross-
# checks every recorded-complete wave/task against the actual task branch in
# git (`swarm/<runId>/<taskId>`). A branch that vanished after being recorded
# complete is reported as "inconsistent", never silently treated as done —
# resume state that lies is worse than no resume state.
#
# Usage:
#   resume-state.sh record-wave <n>        mark wave n complete
#   resume-state.sh record-task <taskId>   mark one task complete
#   resume-state.sh status [--human]       JSON report (default) or text
#   resume-state.sh next-wave              bare integer: wave to resume from
#   resume-state.sh clear                  discard resume state
#
# State lives entirely under .swarm/resume/ inside the repo the current
# directory belongs to. Nothing is ever written outside .swarm/.
#
# Exit 0 on success. Non-zero when a failure is detected (bad arguments, or
# `status` finding recorded state that git no longer backs up) — the reason
# is always on stdout, never only in an exit code.
#
# Written for bash 3.2 (what macOS ships): no associative arrays, no
# namerefs, no readarray/mapfile. Depends on git, jq, awk, sed, grep only.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "error: not inside a git repository"
  exit 1
fi

SWARM_DIR="${REPO_ROOT}/.swarm"
RESUME_DIR="${SWARM_DIR}/resume"
TASK_GRAPH="${SWARM_DIR}/task-graph.json"
WAVES_FILE="${RESUME_DIR}/waves-done"
TASKS_FILE="${RESUME_DIR}/tasks-done"

_jstr() {
  local val="$1"
  if [[ -z "$val" ]]; then
    echo "null"
  else
    val=$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '"%s"' "$val"
  fi
}

_git() { git -C "$REPO_ROOT" "$@"; }

_wave_recorded() {
  [[ -f "$WAVES_FILE" ]] && grep -qxF "$1" "$WAVES_FILE" 2>/dev/null
}

_task_recorded() {
  [[ -f "$TASKS_FILE" ]] && grep -qxF "$1" "$TASKS_FILE" 2>/dev/null
}

_branch_exists() {
  _git show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

# --- record-wave -------------------------------------------------------------

cmd_record_wave() {
  local wave="${1:-}"
  if [[ -z "$wave" || ! "$wave" =~ ^[0-9]+$ || "$wave" -lt 1 ]]; then
    echo "error: wave must be a positive integer, got '${wave}'"
    return 1
  fi
  mkdir -p "$RESUME_DIR"
  if ! grep -qxF "$wave" "$WAVES_FILE" 2>/dev/null; then
    printf '%s\n' "$wave" >> "$WAVES_FILE"
  fi
  echo "recorded: wave ${wave} complete"
  return 0
}

# --- record-task ---------------------------------------------------------

cmd_record_task() {
  local tid="${1:-}"
  if [[ -z "$tid" || ! "$tid" =~ ^T[0-9]+$ ]]; then
    echo "error: taskId must look like T<n>, got '${tid}'"
    return 1
  fi
  mkdir -p "$RESUME_DIR"
  if ! grep -qxF "$tid" "$TASKS_FILE" 2>/dev/null; then
    printf '%s\n' "$tid" >> "$TASKS_FILE"
  fi
  echo "recorded: task ${tid} complete"
  return 0
}

# --- clear -----------------------------------------------------------------

cmd_clear() {
  if [[ -d "$RESUME_DIR" ]]; then
    rm -rf "$RESUME_DIR"
    echo "cleared resume state at ${RESUME_DIR}"
  else
    echo "no resume state to clear"
  fi
  return 0
}

# --- shared computation for status / next-wave ------------------------------
#
# Sets: RUN_ID, GRAPH_ERROR, WAVES_JSON, NEXT_WAVE, CONSISTENT, HUMAN_REPORT.
# Never prints. `_task_graph_valid` failures (missing/malformed file, missing
# jq) degrade to "no waves known" rather than crashing.

_task_graph_valid() {
  [[ -f "$TASK_GRAPH" ]] || { GRAPH_ERROR="task-graph.json not found at ${TASK_GRAPH}"; return 1; }
  command -v jq >/dev/null 2>&1 || { GRAPH_ERROR="jq is required to read task-graph.json"; return 1; }
  jq -e . "$TASK_GRAPH" >/dev/null 2>&1 || { GRAPH_ERROR="task-graph.json is not valid JSON"; return 1; }
  return 0
}

_compute_status() {
  RUN_ID=""
  GRAPH_ERROR=""
  WAVES_JSON=""
  NEXT_WAVE=1
  CONSISTENT="true"
  HUMAN_REPORT=""

  local table="" wave_nums="" any_inconsistent=0 first_unresolved="" max_wave=0

  if _task_graph_valid; then
    RUN_ID=$(jq -r '.runId // empty' "$TASK_GRAPH" 2>/dev/null)
    table=$(jq -r '.waves[] | .wave as $w | .tasks[] | "\($w)\t\(.taskId)"' "$TASK_GRAPH" 2>/dev/null)
    [[ -n "$table" ]] && wave_nums=$(printf '%s\n' "$table" | awk -F'\t' '{print $1}' | sort -nu)
  fi

  if [[ -n "$wave_nums" ]]; then
    while IFS= read -r wnum; do
      [[ -z "$wnum" ]] && continue
      (( wnum > max_wave )) && max_wave=$wnum

      local wave_recorded=0
      _wave_recorded "$wnum" && wave_recorded=1

      local task_ids complete_count=0 total_count=0 inconsistent_here=0
      local tasks_json="" human_tasks=""
      task_ids=$(printf '%s\n' "$table" | awk -F'\t' -v w="$wnum" '$1==w {print $2}')

      while IFS= read -r tid; do
        [[ -z "$tid" ]] && continue
        total_count=$((total_count + 1))

        local recorded=0
        _task_recorded "$tid" && recorded=1
        [[ $wave_recorded -eq 1 ]] && recorded=1

        local branch="swarm/${RUN_ID}/${tid}"
        local branch_exists="false"
        if [[ -n "$RUN_ID" ]] && _branch_exists "$branch"; then
          branch_exists="true"
        fi

        local tstatus
        if [[ $recorded -eq 1 && "$branch_exists" == "true" ]]; then
          tstatus="complete"
          complete_count=$((complete_count + 1))
        elif [[ $recorded -eq 1 && "$branch_exists" == "false" ]]; then
          tstatus="inconsistent"
          inconsistent_here=1
        else
          tstatus="not-started"
        fi

        tasks_json="${tasks_json}{\"taskId\":$(_jstr "$tid"),\"status\":$(_jstr "$tstatus"),\"branch\":$(_jstr "$branch"),\"branchExists\":${branch_exists}},"
        human_tasks="${human_tasks}    - ${tid}: ${tstatus} (branch ${branch}: ${branch_exists})"$'\n'
      done <<< "$task_ids"

      local wstatus
      if [[ $inconsistent_here -eq 1 ]]; then
        wstatus="inconsistent"
        any_inconsistent=1
      elif [[ $total_count -gt 0 && $complete_count -eq $total_count ]]; then
        wstatus="complete"
      elif [[ $complete_count -gt 0 ]]; then
        wstatus="partial"
      else
        wstatus="not-started"
      fi

      if [[ "$wstatus" != "complete" && -z "$first_unresolved" ]]; then
        first_unresolved=$wnum
      fi

      tasks_json="${tasks_json%,}"
      WAVES_JSON="${WAVES_JSON}{\"wave\":${wnum},\"status\":$(_jstr "$wstatus"),\"tasks\":[${tasks_json}]},"
      HUMAN_REPORT="${HUMAN_REPORT}wave ${wnum}: ${wstatus}"$'\n'"${human_tasks}"
    done <<< "$wave_nums"
  fi

  WAVES_JSON="${WAVES_JSON%,}"

  if [[ -n "$first_unresolved" ]]; then
    NEXT_WAVE=$first_unresolved
  elif [[ $max_wave -gt 0 ]]; then
    NEXT_WAVE=$((max_wave + 1))
  else
    # No usable task graph. Best effort from recorded waves alone, so a
    # dead-graph repo still resumes past what was explicitly recorded.
    NEXT_WAVE=1
    if [[ -f "$WAVES_FILE" ]]; then
      local last
      last=$(sort -n "$WAVES_FILE" 2>/dev/null | tail -1)
      [[ -n "$last" ]] && NEXT_WAVE=$((last + 1))
    fi
  fi

  [[ $any_inconsistent -eq 1 ]] && CONSISTENT="false"
}

# --- status ------------------------------------------------------------------

cmd_status() {
  local human=0
  [[ "${1:-}" == "--human" ]] && human=1

  _compute_status

  if [[ $human -eq 1 ]]; then
    echo "run id:    ${RUN_ID:-(none)}"
    echo "consistent: ${CONSISTENT}"
    echo "next wave: ${NEXT_WAVE}"
    [[ -n "$GRAPH_ERROR" ]] && echo "note:      ${GRAPH_ERROR}"
    if [[ -n "$HUMAN_REPORT" ]]; then
      echo
      printf '%s' "$HUMAN_REPORT"
    fi
  else
    printf '{"runId":%s,"consistent":%s,"nextWave":%d,"waves":[%s],"error":%s}\n' \
      "$(_jstr "$RUN_ID")" "$CONSISTENT" "$NEXT_WAVE" "$WAVES_JSON" "$(_jstr "$GRAPH_ERROR")"
  fi

  [[ "$CONSISTENT" == "false" ]] && return 1
  return 0
}

# --- next-wave ---------------------------------------------------------------

cmd_next_wave() {
  _compute_status
  echo "$NEXT_WAVE"
  return 0
}

# --- dispatch ----------------------------------------------------------------

_usage() {
  cat <<'EOF'
usage: resume-state.sh <command> [args]

commands:
  record-wave <n>        mark wave n complete
  record-task <taskId>   mark one task complete (finer grain than a wave)
  status [--human]       report progress as JSON (default) or human text
  next-wave              print the wave number to resume from
  clear                  discard resume state for a fresh run
EOF
}

case "${1:-}" in
  record-wave) cmd_record_wave "${2:-}"; exit $? ;;
  record-task) cmd_record_task "${2:-}"; exit $? ;;
  status)      cmd_status "${2:-}"; exit $? ;;
  next-wave)   cmd_next_wave; exit $? ;;
  clear)       cmd_clear; exit $? ;;
  *)
    _usage
    exit 1
    ;;
esac
