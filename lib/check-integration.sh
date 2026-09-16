#!/usr/bin/env bash
# check-integration.sh — Cross-task semantic conflict detection.
#
# The swarm guarantees no MERGE conflicts, by exclusive file ownership. It says
# nothing about whether the merged result compiles. Two tasks with disjoint
# file sets can still break each other: task A renames or deletes a function
# in its own file, task B still calls the old name from its own file. Git
# merges both without complaint; the build is the first place that notices,
# and by then nobody can tell which task caused it.
#
# This script closes part of that gap by diffing each branch against the
# merge base with the run's base branch, extracting the symbols each branch
# REMOVED (the dangerous set) and the symbols each branch REFERENCED, and
# cross-referencing them: branch A removes `foo`, branch B still references
# `foo` -> reported collision, naming the symbol and both branches.
#
# Deliberately textual and heuristic, not a real parser. A cross-language type
# checker is out of proportion for a plugin with no build step of its own, and
# the failure this catches is visible in the diff without one. That trade-off
# means false negatives exist (see the per-language limits below); the
# mitigation is that this is one of three layers named in docs/orchestration.md
# section 4 — the merge build in phase 5 is the backstop this cannot replace.
#
# FALSE POSITIVES ARE THE FAILURE THIS TOOL MUST AVOID. A check the operator
# disables is worth nothing, so the design leans hard toward silence over
# noise:
#   - comments and the common block/doc-string openers are stripped before
#     matching, best-effort (see strip_comment below for exact limits)
#   - a symbol removed in one place and re-added elsewhere in the SAME branch
#     is a move, not a removal, and is never flagged
#   - very short or generic identifiers are never flagged (edit the lists below)
#   - an unrecognised file extension is reported as a coverage gap, never
#     silently skipped and never guessed at
#   - the process exits non-zero only for an evidenced collision; anything
#     uncertain (no merge base, an unrecognised extension) is reported, not
#     failed on
#
# Usage:
#   check-integration.sh <base-branch> <branch1> [branch2 ...] [--text]
#   check-integration.sh --task-graph <task-graph.json> [--base <branch>] [--text]
#
# In --task-graph mode, every taskId across every wave is compared; the branch
# for taskId T is assumed to be swarm/<runId>/<T>, matching how the orchestrator
# names task branches (skills/swarm/SKILL.md, Phase 2). --base overrides the
# graph's own baseBranch field when given.
#
# Exit codes:
#   0  no collisions found
#   1  at least one collision found
#   2  usage error (bad arguments, missing branch, not a git repo)
#
# Written for bash 3.2, which is what macOS still ships. No associative
# arrays, no `local -n` namerefs, no `readarray`/`mapfile` — plain indexed
# arrays only, and every array is walked by index (`${#arr[@]}`), never with
# `${arr[@]}` directly, because bash 3.2 treats a zero-element array as unset
# under `set -u` for that form.
set -uo pipefail

# --- Ignore lists, at the top and easy to extend ----------------------------

# Symbols at or under this length, or matching one of these names
# (case-insensitive), are never flagged as removed or referenced. They are too
# generic to mean the same thing in two different files.
MIN_SYMBOL_LEN=3
IGNORE_SYMBOLS="get set run main test init new done ok add log map new_"

# Tokens that look like a call (`word(`) but are language keywords, not a
# reference to a removed symbol. Extend this before extending anything else if
# a false positive shows up.
KEYWORDS="if for while switch catch return new typeof instanceof in of do else
case with using foreach lock try function delete await yield throw void sizeof
defined unless until begin ensure elsif elif fn match"

# Shell has no call syntax — `foo arg` invokes foo exactly the way `if` or
# `echo` do — so a bareword at the start of a shell statement is treated as a
# reference (see extract_shell_ref). These are the barewords that are control
# flow, builtins, or common external commands rather than a call to project
# code, and must not be reported as a reference themselves. Extend this list
# rather than accepting a false positive on some other common command.
SHELL_KEYWORDS="if then else elif fi for while until do done case esac function
select in time local declare typeset export readonly return exit set shift
unset trap echo printf read cd pushd popd source eval exec wait break continue
true false test cat grep sed awk ls mkdir rm cp mv chmod trap"

# --- Language support --------------------------------------------------------
# Extension -> language label. Anything else is a reported coverage gap, never
# analysed and never a source of a false positive.
get_lang() {
  case "$1" in
    js|jsx|mjs|cjs) echo "javascript" ;;
    ts|tsx) echo "typescript" ;;
    py) echo "python" ;;
    go) echo "go" ;;
    rs) echo "rust" ;;
    cs) echo "csharp" ;;
    rb) echo "ruby" ;;
    sh|bash|zsh) echo "shell" ;;
    *) echo "" ;;
  esac
}

# How to strip a trailing line comment for that language family. Best-effort:
# this is a plain string cut at the first comment token, so a "//" or "#"
# inside a string literal earlier on the line will truncate it early. Rare in
# a definition or a call site, which is all this tool looks at.
comment_style() {
  case "$1" in
    js|jsx|mjs|cjs|ts|tsx|go|rs|cs) echo "clike" ;;
    py|rb|sh|bash|zsh) echo "hash" ;;
    *) echo "" ;;
  esac
}

strip_comment() {
  local line="$1" style="$2"
  case "$style" in
    clike) printf '%s' "${line%%//*}" ;;
    hash)  printf '%s' "${line%%#*}" ;;
    *)     printf '%s' "$line" ;;
  esac
}

# Whole-line comment/doc-string openers worth dropping outright. Does not
# track multi-line block comments or triple-quoted strings across lines —
# that needs a stateful parser, which is exactly what this tool declines to
# be. A definition or call site inside one of those is a known blind spot.
is_comment_only_line() {
  printf '%s' "$1" | grep -qE '^[[:space:]]*(/\*|\*/?|"""|'"'''"')'
}

is_ignored() {
  local s="$1" low ig
  [[ ${#s} -lt $MIN_SYMBOL_LEN ]] && return 0
  low=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  for ig in $IGNORE_SYMBOLS; do
    [[ "$low" == "$ig" ]] && return 0
  done
  return 1
}

is_keyword() {
  local s="$1" low kw
  low=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  for kw in $KEYWORDS; do
    [[ "$low" == "$kw" ]] && return 0
  done
  return 1
}

is_shell_keyword() {
  local s="$1" low kw
  low=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  for kw in $SHELL_KEYWORDS; do
    [[ "$low" == "$kw" ]] && return 0
  done
  return 1
}

_RE_SHELL_ASSIGN='^[A-Za-z_][A-Za-z0-9_]*\+?='
_RE_SHELL_WORD='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)([[:space:]]|$)'

# A shell statement calls a function the same way it calls any other command:
# a bareword, optionally followed by arguments, at the start of the line (or
# after `&&`, `||`, `;`, `|`). Only the leading word is worth the risk of
# extracting — the rest of the line is arguments and options, not references.
extract_shell_ref() {
  local line="$1"
  [[ "$line" =~ $_RE_SHELL_ASSIGN ]] && { printf ''; return; }
  if [[ "$line" =~ $_RE_SHELL_WORD ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Recognises the shapes named in the task: function foo, def foo, func Foo,
# fn foo, class Foo, const foo =, export ... foo, foo() {, public ... Foo(.
# Applied uniformly across languages rather than gated per-extension — the
# shapes barely overlap, and a stray match (e.g. Python code matching the
# generic "foo() {" pattern) still has to survive the ignore list and the
# cross-reference before it can produce any output.
# bash 3.2 mis-parses some complex regexes typed directly inside `[[ =~ ]]`
# (escaped parens next to bracket expressions confuse its own tokenizer), so
# every pattern is built in a variable first and referenced unquoted.
_RE_FUNCTION='^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?function\*?[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)'
_RE_CONST='^[[:space:]]*(export[[:space:]]+)?(const|let|var)[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)[[:space:]]*='
_RE_CLASS='^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?((public|private|protected|internal|static|abstract|sealed|partial)[[:space:]]+)*class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)'
_RE_DEF='^[[:space:]]*def[[:space:]]+(self\.)?([A-Za-z_][A-Za-z0-9_?!]*)'
_RE_GOFUNC='^[[:space:]]*func[[:space:]]+(\([^)]*\)[[:space:]]*)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\('
_RE_RUSTFN='^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)'
_RE_RUSTTYPE='^[[:space:]]*(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(struct|enum|trait)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)'
_RE_CSHARP='^[[:space:]]*((public|private|protected|internal|static|virtual|override|async|sealed|abstract|readonly)[[:space:]]+){1,}[A-Za-z_][A-Za-z0-9_<>\[\],.]*[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\('
_RE_SHORTHAND='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*$'

def_symbol() {
  local line="$1"
  if [[ "$line" =~ $_RE_FUNCTION ]]; then printf '%s' "${BASH_REMATCH[4]}"; return; fi
  if [[ "$line" =~ $_RE_CONST ]]; then printf '%s' "${BASH_REMATCH[3]}"; return; fi
  if [[ "$line" =~ $_RE_CLASS ]]; then printf '%s' "${BASH_REMATCH[5]}"; return; fi
  if [[ "$line" =~ $_RE_DEF ]]; then printf '%s' "${BASH_REMATCH[2]}"; return; fi
  if [[ "$line" =~ $_RE_GOFUNC ]]; then printf '%s' "${BASH_REMATCH[2]}"; return; fi
  if [[ "$line" =~ $_RE_RUSTFN ]]; then printf '%s' "${BASH_REMATCH[4]}"; return; fi
  if [[ "$line" =~ $_RE_RUSTTYPE ]]; then printf '%s' "${BASH_REMATCH[4]}"; return; fi
  if [[ "$line" =~ $_RE_CSHARP ]]; then printf '%s' "${BASH_REMATCH[3]}"; return; fi
  if [[ "$line" =~ $_RE_SHORTHAND ]]; then printf '%s' "${BASH_REMATCH[1]}"; return; fi
  printf ''
}

_jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g'; }

# --- Argument parsing --------------------------------------------------------

usage_error() {
  echo "{\"error\":\"$(_jesc "$1")\"}"
  echo "usage: check-integration.sh <base-branch> <branch1> [branch2 ...] [--text]" >&2
  echo "       check-integration.sh --task-graph <task-graph.json> [--base <branch>] [--text]" >&2
  exit 2
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  usage_error "not a git repository"
fi

MODE="branches"
TASK_GRAPH=""
BASE=""
TEXT_MODE=0
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-graph)
      [[ $# -lt 2 ]] && usage_error "--task-graph requires a path"
      TASK_GRAPH="$2"; MODE="task-graph"; shift 2 ;;
    --base)
      [[ $# -lt 2 ]] && usage_error "--base requires a branch name"
      BASE="$2"; shift 2 ;;
    --text|--human)
      TEXT_MODE=1; shift ;;
    -*)
      usage_error "unknown option: $1" ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

LABELS=()
BRANCHES=()

if [[ "$MODE" == "task-graph" ]]; then
  [[ -f "$TASK_GRAPH" ]] || usage_error "task graph not found: $TASK_GRAPH"
  command -v jq >/dev/null 2>&1 || usage_error "jq is required for --task-graph mode"
  RUN_ID=$(jq -r '.runId // empty' "$TASK_GRAPH" 2>/dev/null)
  [[ -z "$RUN_ID" ]] && usage_error "task graph has no runId: $TASK_GRAPH"
  if [[ -z "$BASE" ]]; then
    BASE=$(jq -r '.baseBranch // empty' "$TASK_GRAPH" 2>/dev/null)
  fi
  [[ -z "$BASE" ]] && usage_error "no base branch given and task graph has no baseBranch"
  TASK_IDS=$(jq -r '.waves[].tasks[].taskId' "$TASK_GRAPH" 2>/dev/null)
  [[ -z "$TASK_IDS" ]] && usage_error "task graph has no tasks: $TASK_GRAPH"
  while IFS= read -r tid; do
    [[ -z "$tid" ]] && continue
    LABELS+=("$tid")
    BRANCHES+=("swarm/${RUN_ID}/${tid}")
  done <<< "$TASK_IDS"
else
  [[ -n "$BASE" ]] || { [[ ${#POSITIONAL[@]} -gt 0 ]] && { BASE="${POSITIONAL[0]}"; POSITIONAL=("${POSITIONAL[@]:1}"); }; }
  [[ -z "$BASE" ]] && usage_error "no base branch given"
  [[ ${#POSITIONAL[@]} -eq 0 ]] && usage_error "no branches given to compare"
  for b in "${POSITIONAL[@]}"; do
    LABELS+=("$b")
    BRANCHES+=("$b")
  done
fi

branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1" && return 0
  git show-ref --verify --quiet "refs/remotes/origin/$1" && return 0
  return 1
}

branch_exists "$BASE" || usage_error "base branch not found: $BASE"
for ((i = 0; i < ${#BRANCHES[@]}; i++)); do
  branch_exists "${BRANCHES[i]}" || usage_error "branch not found: ${BRANCHES[i]}"
done

# --- Per-branch analysis -----------------------------------------------------
# Each REMOVED/ADDEDDEFS/REFERENCED/ANALYZED/GAPS entry is a newline-separated
# list of tab-separated records, indexed in parallel with LABELS/BRANCHES.

N=${#BRANCHES[@]}
REMOVED=()
ADDEDDEFS=()
REFERENCED=()
ANALYZED=()
GAPS=()
BRANCH_ERR=()

for ((i = 0; i < N; i++)); do
  REMOVED[i]=""
  ADDEDDEFS[i]=""
  REFERENCED[i]=""
  ANALYZED[i]=""
  GAPS[i]=""
  BRANCH_ERR[i]=""

  branch="${BRANCHES[i]}"
  mb=$(git merge-base "$BASE" "$branch" 2>/dev/null)
  if [[ -z "$mb" ]]; then
    BRANCH_ERR[i]="no common history with $BASE"
    continue
  fi

  diff=$(git diff --no-color "$mb" "$branch" -- 2>/dev/null)

  current_file=""
  current_supported=0
  current_style=""
  current_lang=""

  while IFS= read -r line; do
    case "$line" in
      "diff --git "*)
        newpath=$(printf '%s' "$line" | sed -E 's#^diff --git a/.* b/##')
        current_file="$newpath"
        base_name="${newpath##*/}"
        ext="${base_name##*.}"
        [[ "$ext" == "$base_name" ]] && ext=""
        lang=$(get_lang "$ext")
        if [[ -n "$lang" ]]; then
          current_supported=1
          current_style=$(comment_style "$ext")
          current_lang="$lang"
          ANALYZED[i]="${ANALYZED[i]}${lang}"$'\t'"${current_file}"$'\n'
        else
          current_supported=0
          GAPS[i]="${GAPS[i]}${ext:-noext}"$'\t'"${current_file}"$'\n'
        fi
        ;;
      "--- "* | "+++ "* | "index "* | "new file mode"* | "deleted file mode"* | \
      "similarity index"* | "rename from"* | "rename to"* | "Binary files"* | "@@ "*)
        : ;;
      "-"*)
        [[ "$current_supported" -eq 1 ]] || continue
        raw="${line#-}"
        stripped=$(strip_comment "$raw" "$current_style")
        is_comment_only_line "$stripped" && continue
        sym=$(def_symbol "$stripped")
        if [[ -n "$sym" ]] && ! is_ignored "$sym"; then
          REMOVED[i]="${REMOVED[i]}${sym}"$'\t'"${current_file}"$'\n'
        fi
        ;;
      "+"*)
        [[ "$current_supported" -eq 1 ]] || continue
        raw="${line#+}"
        stripped=$(strip_comment "$raw" "$current_style")
        is_comment_only_line "$stripped" && continue
        # A line can be BOTH a definition and a reference at once —
        # `const total = formatPrice(amount);` defines `total` and calls
        # `formatPrice` — so these are not mutually exclusive branches. Only
        # the shell bareword heuristic is skipped on a line already
        # recognised as a definition, since there `foo() {` would otherwise
        # also register `foo` as a call to itself.
        sym=$(def_symbol "$stripped")
        is_def_line=0
        if [[ -n "$sym" ]]; then
          is_def_line=1
          if ! is_ignored "$sym"; then
            ADDEDDEFS[i]="${ADDEDDEFS[i]}${sym}"$'\n'
          fi
        fi
        refs=$(printf '%s\n' "$stripped" | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' 2>/dev/null || true)
        if [[ -n "$refs" ]]; then
          while IFS= read -r m; do
            [[ -z "$m" ]] && continue
            rsym="${m%(}"
            rsym=$(printf '%s' "$rsym" | sed -E 's/[[:space:]]+$//')
            [[ "$is_def_line" -eq 1 && "$rsym" == "$sym" ]] && continue
            if [[ -n "$rsym" ]] && ! is_ignored "$rsym" && ! is_keyword "$rsym"; then
              REFERENCED[i]="${REFERENCED[i]}${rsym}"$'\t'"${current_file}"$'\n'
            fi
          done <<< "$refs"
        fi
        if [[ "$current_lang" == "shell" && "$is_def_line" -eq 0 ]]; then
          rsym=$(extract_shell_ref "$stripped")
          if [[ -n "$rsym" ]] && ! is_ignored "$rsym" && ! is_keyword "$rsym" && ! is_shell_keyword "$rsym"; then
            REFERENCED[i]="${REFERENCED[i]}${rsym}"$'\t'"${current_file}"$'\n'
          fi
        fi
        ;;
      *) : ;;
    esac
  done <<< "$diff"
done

# --- Cross-reference ---------------------------------------------------------

COLLISIONS=""
for ((i = 0; i < N; i++)); do
  [[ -z "${REMOVED[i]}" ]] && continue
  while IFS=$'\t' read -r sym file; do
    [[ -z "$sym" ]] && continue
    if printf '%s\n' "${ADDEDDEFS[i]}" | grep -qxF "$sym"; then
      continue # moved within the same branch, not a removal
    fi
    for ((j = 0; j < N; j++)); do
      [[ "$j" -eq "$i" ]] && continue
      [[ -z "${REFERENCED[j]}" ]] && continue
      matched=$(printf '%s\n' "${REFERENCED[j]}" | awk -F'\t' -v s="$sym" '$1==s{print $2}')
      [[ -z "$matched" ]] && continue
      while IFS= read -r reffile; do
        [[ -z "$reffile" ]] && continue
        COLLISIONS="${COLLISIONS}${sym}"$'\t'"${LABELS[i]}"$'\t'"${file}"$'\t'"${LABELS[j]}"$'\t'"${reffile}"$'\n'
      done <<< "$matched"
    done
  done <<< "${REMOVED[i]}"
done

COLLISIONS_UNIQ=$(printf '%s' "$COLLISIONS" | sed '/^$/d' | sort -u)
COLLISION_COUNT=0
if [[ -n "$COLLISIONS_UNIQ" ]]; then
  COLLISION_COUNT=$(printf '%s\n' "$COLLISIONS_UNIQ" | sed '/^$/d' | wc -l | tr -d ' ')
fi

# --- Output -------------------------------------------------------------------

if [[ "$TEXT_MODE" -eq 1 ]]; then
  echo "check-integration: base=${BASE}"
  for ((i = 0; i < N; i++)); do
    if [[ -n "${BRANCH_ERR[i]}" ]]; then
      echo "  ${LABELS[i]} (${BRANCHES[i]}): ${BRANCH_ERR[i]}"
      continue
    fi
    files_n=$(printf '%s\n' "${ANALYZED[i]}" | sed '/^$/d' | wc -l | tr -d ' ')
    gaps_n=$(printf '%s\n' "${GAPS[i]}" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "  ${LABELS[i]} (${BRANCHES[i]}): ${files_n} file(s) analysed, ${gaps_n} not analysed"
    if [[ -n "${GAPS[i]}" ]]; then
      printf '%s\n' "${GAPS[i]}" | sed '/^$/d' | awk -F'\t' '{c[$1]++} END{for (e in c) printf "    %d files in %s were not analysed\n", c[e], e}'
    fi
  done
  echo
  if [[ "$COLLISION_COUNT" -eq 0 ]]; then
    echo "No collisions found."
  else
    echo "Collisions (${COLLISION_COUNT}):"
    printf '%s\n' "$COLLISIONS_UNIQ" | while IFS=$'\t' read -r sym rl rf jl jf; do
      [[ -z "$sym" ]] && continue
      echo "  '${sym}' removed by ${rl} (${rf}) but still referenced by ${jl} (${jf})"
    done
  fi
  [[ "$COLLISION_COUNT" -gt 0 ]] && exit 1
  exit 0
fi

compared_json="["
for ((i = 0; i < N; i++)); do
  compared_json="${compared_json}{\"label\":\"$(_jesc "${LABELS[i]}")\",\"branch\":\"$(_jesc "${BRANCHES[i]}")\"},"
done
compared_json="${compared_json%,}]"

errors_json="["
for ((i = 0; i < N; i++)); do
  [[ -z "${BRANCH_ERR[i]}" ]] && continue
  errors_json="${errors_json}{\"label\":\"$(_jesc "${LABELS[i]}")\",\"branch\":\"$(_jesc "${BRANCHES[i]}")\",\"message\":\"$(_jesc "${BRANCH_ERR[i]}")\"},"
done
errors_json="${errors_json%,}]"

analyzed_json="["
total_files_analyzed=0
for ((i = 0; i < N; i++)); do
  [[ -n "${BRANCH_ERR[i]}" ]] && continue
  files_n=$(printf '%s\n' "${ANALYZED[i]}" | sed '/^$/d' | wc -l | tr -d ' ')
  total_files_analyzed=$((total_files_analyzed + files_n))
  langs=$(printf '%s\n' "${ANALYZED[i]}" | sed '/^$/d' | awk -F'\t' '{print $1}' | sort -u)
  langs_json="["
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    langs_json="${langs_json}\"$(_jesc "$l")\","
  done <<< "$langs"
  langs_json="${langs_json%,}]"
  analyzed_json="${analyzed_json}{\"label\":\"$(_jesc "${LABELS[i]}")\",\"branch\":\"$(_jesc "${BRANCHES[i]}")\",\"filesAnalyzed\":${files_n},\"languages\":${langs_json}},"
done
analyzed_json="${analyzed_json%,}]"

gaps_json="["
total_files_unanalyzed=0
for ((i = 0; i < N; i++)); do
  [[ -n "${BRANCH_ERR[i]}" ]] && continue
  [[ -z "${GAPS[i]}" ]] && continue
  while IFS=$'\t' read -r ext count; do
    [[ -z "$ext" ]] && continue
    total_files_unanalyzed=$((total_files_unanalyzed + count))
    msg="${count} files in ${ext} were not analysed"
    gaps_json="${gaps_json}{\"label\":\"$(_jesc "${LABELS[i]}")\",\"branch\":\"$(_jesc "${BRANCHES[i]}")\",\"extension\":\"$(_jesc "$ext")\",\"files\":${count},\"message\":\"$(_jesc "$msg")\"},"
  done <<< "$(printf '%s\n' "${GAPS[i]}" | sed '/^$/d' | awk -F'\t' '{c[$1]++} END{for (e in c) print e"\t"c[e]}')"
done
gaps_json="${gaps_json%,}]"

collisions_json="["
if [[ -n "$COLLISIONS_UNIQ" ]]; then
  while IFS=$'\t' read -r sym rl rf jl jf; do
    [[ -z "$sym" ]] && continue
    collisions_json="${collisions_json}{\"symbol\":\"$(_jesc "$sym")\",\"removedBy\":\"$(_jesc "$rl")\",\"removedIn\":\"$(_jesc "$rf")\",\"referencedBy\":\"$(_jesc "$jl")\",\"referencedIn\":\"$(_jesc "$jf")\"},"
  done <<< "$COLLISIONS_UNIQ"
fi
collisions_json="${collisions_json%,}]"

cat <<JSON
{
  "base": "$(_jesc "$BASE")",
  "compared": ${compared_json},
  "collisions": ${collisions_json},
  "analyzed": ${analyzed_json},
  "gaps": ${gaps_json},
  "errors": ${errors_json},
  "summary": {
    "branchesChecked": ${N},
    "collisionCount": ${COLLISION_COUNT},
    "filesAnalyzed": ${total_files_analyzed},
    "filesUnanalyzed": ${total_files_unanalyzed}
  }
}
JSON

[[ "$COLLISION_COUNT" -gt 0 ]] && exit 1
exit 0
