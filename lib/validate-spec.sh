#!/usr/bin/env bash
# validate-spec.sh — Validate a swarm-spec file against the schema.
#
# Usage: validate-spec.sh <spec.md>
#   exit 0  valid
#   exit 1  invalid (errors printed to stdout)
#   exit 2  usage error
#
# Enforces the eight rules in skills/swarm-spec/schema.md. Rule 8 — exclusive
# file ownership — is the one that makes parallel execution safe; it is checked
# here, at authoring time, rather than discovered halfway through a run.
#
# Written for bash 3.2, which is what macOS still ships. No associative arrays,
# no namerefs, no `readarray`.
set -uo pipefail

SPEC_FILE="${1:-}"
ERROR_COUNT=0
WARN_COUNT=0
ERROR_TEXT=""
WARN_TEXT=""

if [[ -z "$SPEC_FILE" ]]; then
  echo "usage: validate-spec.sh <spec.md>" >&2
  exit 2
fi
if [[ ! -f "$SPEC_FILE" ]]; then
  echo "ERROR: file not found: $SPEC_FILE" >&2
  exit 2
fi

err()  { ERROR_TEXT="${ERROR_TEXT}  - $1"$'\n'; ERROR_COUNT=$((ERROR_COUNT + 1)); }
warn() { WARN_TEXT="${WARN_TEXT}  - $1"$'\n';  WARN_COUNT=$((WARN_COUNT + 1)); }

report_and_exit() {
  if (( WARN_COUNT > 0 )); then
    echo "WARNINGS (${WARN_COUNT}):"
    printf '%s' "$WARN_TEXT"
    echo
  fi
  if (( ERROR_COUNT > 0 )); then
    echo "INVALID: ${SPEC_FILE}"
    echo "ERRORS (${ERROR_COUNT}):"
    printf '%s' "$ERROR_TEXT"
    exit 1
  fi
  echo "VALID: ${SPEC_FILE}"
  exit 0
}

# --- Rule 1: frontmatter present -------------------------------------------
if [[ "$(head -1 "$SPEC_FILE")" != "---" ]]; then
  err "Rule 1: file does not start with a '---' frontmatter delimiter."
  report_and_exit
fi

frontmatter=$(awk 'NR==1 && /^---$/ {next} /^---$/ {exit} {print}' "$SPEC_FILE")
body=$(awk 'BEGIN{n=0} /^---$/ {n++; next} n>=2 {print}' "$SPEC_FILE")

if [[ -z "$frontmatter" ]]; then
  err "Rule 1: frontmatter block is empty or never closed with '---'."
fi

get_field() {
  echo "$frontmatter" | grep -m1 "^${1}:" | sed "s/^${1}:[[:space:]]*//" | tr -d '"' | tr -d "'" | tr -d '\r'
}

# --- Rule 2: required fields ------------------------------------------------
for field in schema schema_version status owner area spec_id kind; do
  if [[ -z "$(get_field "$field")" ]]; then
    err "Rule 2: required frontmatter field '${field}' is missing."
  fi
done

schema=$(get_field schema)
if [[ -n "$schema" && "$schema" != "swarm-spec" ]]; then
  err "Rule 2: 'schema' must be exactly 'swarm-spec' (found: '${schema}')."
fi

# --- Rule 3: lifecycle status -----------------------------------------------
status=$(get_field status)
case "$status" in
  Draft|Approved|"In Progress"|Verified|Shipped|"") ;;
  *) err "Rule 3: 'status' must be one of Draft, Approved, In Progress, Verified, Shipped (found: '${status}')." ;;
esac

# --- Rule 4: work kind ------------------------------------------------------
kind=$(get_field kind)
case "$kind" in
  feature|bugfix|workflow|refactor|"") ;;
  *) err "Rule 4: 'kind' must be one of feature, bugfix, workflow, refactor (found: '${kind}')." ;;
esac

# --- Rule 5: required sections, in order ------------------------------------
last_pos=0
for section in "## Outcome" "## Scope Boundaries" "## Constraints" "## Task Breakdown" "## Verification Criteria"; do
  pos=$(echo "$body" | grep -n "^${section}[[:space:]]*$" | head -1 | cut -d: -f1)
  if [[ -z "$pos" ]]; then
    err "Rule 5: required section '${section}' is missing."
  elif (( pos < last_pos )); then
    err "Rule 5: section '${section}' appears out of order."
  else
    last_pos=$pos
  fi
done

has_decisions=$(echo "$body" | grep -c "^## Prior Decisions[[:space:]]*$")
has_rootcause=$(echo "$body" | grep -c "^## Root Cause[[:space:]]*$")

if (( has_decisions == 0 && has_rootcause == 0 )); then
  err "Rule 5: exactly one of '## Prior Decisions' or '## Root Cause' is required."
fi
if (( has_decisions > 0 && has_rootcause > 0 )); then
  err "Rule 5: '## Prior Decisions' and '## Root Cause' are mutually exclusive — include one, not both."
fi
if [[ "$kind" == "bugfix" ]] && (( has_rootcause == 0 )); then
  err "Rule 5: a bugfix spec must use '## Root Cause', not '## Prior Decisions'."
fi

# --- Rules 6, 7 (deps), 8: task breakdown -----------------------------------
tasks=$(echo "$body" | awk '/^## Task Breakdown/{f=1;next} /^## /{f=0} f && /^- \[[ xX]\]/ {print}')

if [[ -z "$tasks" ]]; then
  err "Rule 6: '## Task Breakdown' contains no checkbox tasks."
else
  seen_ids=""
  scope_pairs=""
  dep_edges=""

  while IFS= read -r task; do
    [[ -z "$task" ]] && continue

    task_id=$(echo "$task" | grep -oE '\bT[0-9]+\b' | head -1)
    if [[ -z "$task_id" ]]; then
      err "Rule 6: task has no T<n> identifier: ${task:0:70}"
      continue
    fi

    case " ${seen_ids} " in
      *" ${task_id} "*) err "Rule 6: duplicate task id '${task_id}'." ;;
    esac
    seen_ids="${seen_ids} ${task_id}"

    if ! echo "$task" | grep -q '(files:'; then
      err "Rule 6: task ${task_id} has no '(files: ...)' annotation."
      continue
    fi

    files=$(echo "$task" | sed -n 's/.*(files:\([^)]*\)).*/\1/p' \
      | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
    if [[ -z "$files" ]]; then
      err "Rule 6: task ${task_id} has an empty '(files: ...)' annotation."
      continue
    fi

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      scope_pairs="${scope_pairs}${f}|${task_id}"$'\n'
    done <<< "$files"

    # Dependencies are recorded now and resolved after the loop, once every
    # task id is known — a forward reference to a later task is legal.
    deps=$(echo "$task" | sed -n 's/.*(after:\([^)]*\)).*/\1/p' \
      | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$')
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      dep_edges="${dep_edges}${task_id}|${dep}"$'\n'
    done <<< "$deps"
  done <<< "$tasks"

  # Rule 7 — every dependency must resolve to a task defined in this spec.
  while IFS= read -r edge; do
    [[ -z "$edge" ]] && continue
    from="${edge%%|*}"
    to="${edge##*|}"
    if [[ "$from" == "$to" ]]; then
      err "Rule 7: task ${from} declares itself as a dependency."
      continue
    fi
    case " ${seen_ids} " in
      *" ${to} "*) ;;
      *) err "Rule 7: task ${from} depends on '${to}', which is not defined in this spec." ;;
    esac
  done <<< "$dep_edges"

  # Rule 8 — exclusive file ownership across the whole spec.
  #
  # Comparing the raw strings is not enough: `src/api/*.ts` and
  # `src/api/routes.ts` are different strings that claim the same file. Each
  # pair of scope entries from different tasks is therefore tested both ways,
  # using the same segment-aware glob semantics the scope-guard hook enforces
  # at runtime — `*` stays inside one path segment, `**` crosses directories.
  scope_to_regex() {
    printf '%s' "$1" | awk '{
      out = "^"; i = 1; n = length($0)
      while (i <= n) {
        c = substr($0, i, 1)
        if (c == "*") {
          if (substr($0, i + 1, 1) == "*") { out = out ".*"; i += 2 }
          else                             { out = out "[^/]*"; i += 1 }
        } else if (c == "?") {
          out = out "[^/]"; i += 1
        } else if (index(".+^$()[]{}|\\", c) > 0) {
          out = out "\\" c; i += 1
        } else { out = out c; i += 1 }
      }
      print out "$"
    }'
  }

  # A scope entry claims a path if it matches it exactly, is a directory prefix
  # of it, or matches it as a glob.
  claims() {
    local scope="$1" path="$2"
    [[ "$scope" == "$path" ]] && return 0
    [[ "$scope" == */ && "$path" == "$scope"* ]] && return 0
    printf '%s' "$path" | grep -qE "$(scope_to_regex "$scope")" && return 0
    return 1
  }

  entries=$(printf '%s' "$scope_pairs" | grep -v '^$')
  reported=""
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    a_path="${a%%|*}"; a_task="${a##*|}"
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      b_path="${b%%|*}"; b_task="${b##*|}"
      [[ "$a_task" == "$b_task" ]] && continue

      if claims "$a_path" "$b_path" || claims "$b_path" "$a_path"; then
        # Report each unordered pair once.
        key=$(printf '%s\n%s' "${a_task}:${a_path}" "${b_task}:${b_path}" | sort | tr '\n' '~')
        case "$reported" in
          *"[$key]"*) continue ;;
        esac
        reported="${reported}[$key]"

        if [[ "$a_path" == "$b_path" ]]; then
          err "Rule 8: file '${a_path}' is claimed by both ${a_task} and ${b_task}. Either merge those tasks or split the file."
        else
          err "Rule 8: scopes overlap — ${a_task} claims '${a_path}' and ${b_task} claims '${b_path}', which can match the same file. Narrow one of them, or merge the tasks."
        fi
      fi
    done <<< "$entries"
  done <<< "$entries"
fi

# --- Rule 7: verification criteria ------------------------------------------
criteria=$(echo "$body" | awk '/^## Verification Criteria/{f=1;next} /^## /{f=0} f && /^- /{print}')

if [[ -z "$criteria" ]]; then
  err "Rule 7: '## Verification Criteria' contains no criteria."
else
  programmatic_count=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if echo "$c" | grep -q '\[programmatic\]'; then
      programmatic_count=$((programmatic_count + 1))
      if ! echo "$c" | grep -q '`'; then
        warn "Rule 7: programmatic criterion has no backticked command or test name — an agent cannot run it verbatim: ${c:0:70}"
      fi
    elif echo "$c" | grep -q '\[human\]'; then
      :
    else
      err "Rule 7: criterion is not tagged [programmatic] or [human]: ${c:0:70}"
    fi
  done <<< "$criteria"

  if (( programmatic_count == 0 )); then
    err "Rule 7: at least one [programmatic] criterion is required — a spec with only [human] criteria cannot gate a swarm run."
  fi
fi

report_and_exit
