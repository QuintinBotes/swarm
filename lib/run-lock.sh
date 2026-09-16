#!/usr/bin/env bash
# run-lock.sh — Cross-run repository lock, so two swarm runs never share
# .swarm/task-graph.json, .swarm/current-task-id, or .swarm/qa-status/ at once.
#
# Locking primitive: `mkdir .swarm/lock`. mkdir is atomic on every POSIX
# filesystem — exactly one caller among any number of concurrent callers can
# create a given directory, and the others get EEXIST. That is a real mutex
# with no extra dependency. `flock` was considered and rejected: it does not
# ship on macOS, which this repo must run on.
#
# Liveness: a lock is "stale" when the process that took it is gone. The pid
# recorded as the holder defaults to $PPID at acquire/reclaim time — the
# caller's own process — not $$ of this script, which exits the instant the
# subcommand returns and would make every lock stale before the caller could
# even read the result. $PPID is only reliable when the caller invokes this
# script directly from its own long-lived shell; a caller that wraps the call
# in `$(...)` command substitution gets a throwaway subshell as $PPID, which
# is just as dead a moment later. Such a caller should instead export
# RUN_LOCK_PID=$$ once, from its own stable outer shell, before calling
# acquire/reclaim — this script records RUN_LOCK_PID when set, falling back
# to $PPID otherwise. As long as the recorded process stays alive for the
# run's duration, `kill -0 <pid>` tells the truth about whether the run is
# still around. Liveness is always checked with `kill -0 <pid> 2>/dev/null`,
# never by comparing timestamps alone — a long-running run must not be
# treated as stale just because it is slow.
#
# Design decisions not spelled out by the callers of this script:
#   - Re-acquiring with the SAME run id that already holds the lock succeeds
#     as a no-op (it re-affirms the existing metadata rather than erroring).
#     A run that acquires the lock, does work, and acquires again later in
#     the same process should not be punished for holding its own lock.
#   - `reclaim` takes over ONLY a stale lock (dead holder pid) or an absent
#     lock; it always refuses a live lock, matching acquire's own refusal.
#     `reclaim` accepts an optional new-holder run id as its second argument
#     (`run-lock.sh reclaim <run-id>`); when omitted, one is generated from
#     this process's parent pid and the current time so the lock still ends
#     up held by someone identifiable.
#
# Usage:
#   run-lock.sh acquire <run-id>   # take the lock, or fail naming the holder
#   run-lock.sh release <run-id>   # release, only if <run-id> holds it
#   run-lock.sh status             # report holder, pid, age, staleness
#   run-lock.sh reclaim [run-id]   # take over a stale (or absent) lock
#
# Exit codes: 0 success, 1 the detected failure (lock held by another run,
# lock still live, etc. — a human-readable reason is always printed to
# stdout), 2 usage error (bad/missing arguments).
#
# Written for bash 3.2 (macOS's shipped bash): no associative arrays, no
# namerefs, no readarray/mapfile.
#
# All state lives under .swarm/lock in the repo; nothing is ever written
# outside .swarm/. The lock root is the current working directory by default
# (the swarm always runs from the repo root), overridable via SWARM_ROOT for
# testing.
set -uo pipefail

ROOT="${SWARM_ROOT:-$(pwd)}"
SWARM_DIR="${ROOT}/.swarm"
LOCK_DIR="${SWARM_DIR}/lock"
LOCK_INFO="${LOCK_DIR}/info"

# The pid recorded as this call's holder. See the header comment: callers
# that invoke this script through command substitution should export
# RUN_LOCK_PID=$$ from their own stable shell first.
HOLDER_PID="${RUN_LOCK_PID:-$PPID}"

_now() { date +%s; }

_is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Reads one key from the lock's info file. Empty string if missing/corrupt.
_lock_field() {
  local key="$1"
  [[ -f "$LOCK_INFO" ]] || return 0
  grep -m1 "^${key}=" "$LOCK_INFO" 2>/dev/null | cut -d= -f2- || true
}

_write_lock_info() {
  local run_id="$1" pid="$2" started_at="$3"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'pid=%s\n' "$pid"
    printf 'started_at=%s\n' "$started_at"
  } > "$LOCK_INFO"
}

# Age in whole seconds. Empty started_at (corrupt info file) reports as -1
# so callers can tell "unknown" apart from "just created".
_lock_age() {
  local started_at="$1"
  if [[ -z "$started_at" || ! "$started_at" =~ ^[0-9]+$ ]]; then
    echo "-1"
    return 0
  fi
  echo "$(( $(_now) - started_at ))"
}

# Generates a fallback run id for `reclaim` when none is given.
_generate_run_id() {
  printf 'reclaimed-%s-%s' "$HOLDER_PID" "$(_now)"
}

_do_acquire() {
  local run_id="$1"
  mkdir -p "$SWARM_DIR" 2>/dev/null || true

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    _write_lock_info "$run_id" "$HOLDER_PID" "$(_now)"
    echo "acquired lock for run '${run_id}' (pid ${HOLDER_PID})"
    return 0
  fi

  # Lock directory already exists — inspect who holds it.
  local holder pid started_at age
  holder="$(_lock_field run_id)"
  pid="$(_lock_field pid)"
  started_at="$(_lock_field started_at)"
  age="$(_lock_age "$started_at")"

  if [[ -n "$holder" && "$holder" == "$run_id" ]]; then
    echo "lock already held by run '${run_id}' (pid ${pid}); re-acquire is a no-op"
    return 0
  fi

  if [[ -z "$holder" ]]; then
    echo "lock directory exists but its holder metadata is missing or corrupt; refusing to acquire — run 'run-lock.sh reclaim' to take it over"
    return 1
  fi

  if _is_pid_alive "$pid"; then
    echo "lock is held by run '${holder}' (pid ${pid}, age ${age}s); acquire refused"
  else
    echo "lock is held by run '${holder}' (pid ${pid}) but that process is no longer running (stale); acquire refused — run 'run-lock.sh reclaim' to take over"
  fi
  return 1
}

_do_release() {
  local run_id="$1"

  if [[ ! -d "$LOCK_DIR" ]]; then
    echo "no lock is held; nothing to release"
    return 1
  fi

  local holder
  holder="$(_lock_field run_id)"

  if [[ -z "$holder" ]]; then
    echo "lock directory exists but its holder metadata is missing or corrupt; refusing to release — run 'run-lock.sh reclaim' to take it over"
    return 1
  fi

  if [[ "$holder" != "$run_id" ]]; then
    echo "lock is held by run '${holder}', not '${run_id}'; refusing to release another run's lock"
    return 1
  fi

  rm -rf "$LOCK_DIR"
  echo "released lock held by run '${run_id}'"
  return 0
}

_do_status() {
  if [[ ! -d "$LOCK_DIR" ]]; then
    echo "no lock is held"
    return 0
  fi

  local holder pid started_at age
  holder="$(_lock_field run_id)"
  pid="$(_lock_field pid)"
  started_at="$(_lock_field started_at)"
  age="$(_lock_age "$started_at")"

  if [[ -z "$holder" ]]; then
    echo "lock directory exists but its holder metadata is missing or corrupt (treating as stale)"
    return 0
  fi

  if _is_pid_alive "$pid"; then
    echo "lock held by run '${holder}' (pid ${pid}), age ${age}s, live"
  else
    echo "lock held by run '${holder}' (pid ${pid}), age ${age}s, STALE (process not running)"
  fi
  return 0
}

_do_reclaim() {
  local run_id="${1:-}"
  [[ -z "$run_id" ]] && run_id="$(_generate_run_id)"

  if [[ ! -d "$LOCK_DIR" ]]; then
    mkdir -p "$SWARM_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR"
    _write_lock_info "$run_id" "$HOLDER_PID" "$(_now)"
    echo "no lock was held; acquired directly as run '${run_id}' (nothing to reclaim)"
    return 0
  fi

  local holder pid
  holder="$(_lock_field run_id)"
  pid="$(_lock_field pid)"

  if [[ -n "$holder" ]] && _is_pid_alive "$pid"; then
    echo "lock is held by run '${holder}' (pid ${pid}) and that process is still running; refusing to reclaim a live lock"
    return 1
  fi

  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  _write_lock_info "$run_id" "$HOLDER_PID" "$(_now)"
  if [[ -z "$holder" ]]; then
    echo "reclaimed a lock with missing/corrupt holder metadata (treated as stale); now held by run '${run_id}'"
  else
    echo "reclaimed stale lock previously held by run '${holder}' (pid ${pid}, no longer running); now held by run '${run_id}'"
  fi
  return 0
}

COMMAND="${1:-}"

case "$COMMAND" in
  acquire)
    RUN_ID="${2:-}"
    if [[ -z "$RUN_ID" ]]; then
      echo "usage: run-lock.sh acquire <run-id>"
      exit 2
    fi
    _do_acquire "$RUN_ID"
    exit $?
    ;;
  release)
    RUN_ID="${2:-}"
    if [[ -z "$RUN_ID" ]]; then
      echo "usage: run-lock.sh release <run-id>"
      exit 2
    fi
    _do_release "$RUN_ID"
    exit $?
    ;;
  status)
    _do_status
    exit $?
    ;;
  reclaim)
    _do_reclaim "${2:-}"
    exit $?
    ;;
  *)
    echo "usage: run-lock.sh {acquire <run-id>|release <run-id>|status|reclaim [run-id]}"
    exit 2
    ;;
esac
