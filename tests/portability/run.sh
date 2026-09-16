#!/usr/bin/env bash
# run.sh — bash 3.2 portability lint.
#
# WHY THIS EXISTS, and why `bash -n` is not enough.
#
# macOS ships bash 3.2 and this repository targets it. The obvious check —
# "does /bin/bash -n accept the script" — does not work, because bash 4
# builtins are syntactically valid to the 3.2 parser. Worse, they are not fatal
# at runtime either:
#
#   $ /bin/bash -c 'declare -A m; m[x]=1; echo "${m[x]}"'
#   bash: declare: -A: invalid option        <- stderr, non-fatal
#   1                                        <- degraded to a normal array
#   $ echo $?
#   0                                        <- exits clean
#
#   $ /bin/bash -c 'readarray -t a < f; echo "${#a[@]}"'
#   bash: readarray: command not found        <- stderr, non-fatal
#   0                                         <- exits clean
#
# So a script using bash 4 features passes `bash -n`, passes its own test
# suite, exits 0, and silently produces wrong results on every macOS machine.
# Nothing catches it except looking for the constructs directly. That is this
# file.
set -uo pipefail
# portability-lint-exempt

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

PASS=0
FAIL=0

# Each entry: <grep -E pattern>|<what it is>|<what to use on 3.2 instead>
BANNED='declare[[:space:]]+-A|associative arrays (bash 4)|parallel indexed arrays, or a delimited string
local[[:space:]]+-n|namerefs (bash 4.3)|pass the value, or use eval-free indirection
\breadarray\b|readarray (bash 4)|while IFS= read -r line; do ... done < file
\bmapfile\b|mapfile (bash 4)|while IFS= read -r line; do ... done < file
\$\{[A-Za-z_][A-Za-z0-9_]*,,|lowercase expansion ${v,,} (bash 4)|tr "[:upper:]" "[:lower:]"
\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|uppercase expansion ${v^^} (bash 4)|tr "[:lower:]" "[:upper:]"
\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]|negative array index (bash 4.3)|${arr[${#arr[@]}-1]}
\bcoproc\b|coproc (bash 4)|a named pipe, or a background job
&>>|append-both-streams &>> (bash 4)|>>file 2>&1'

scripts=$(find "$ROOT" -name '*.sh' -not -path '*/.git/*' | sort)

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  pattern="${entry%%|*}"
  rest="${entry#*|}"
  label="${rest%%|*}"
  advice="${rest#*|}"

  hits=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Skip any file marked exempt. This lint's own pattern table necessarily
    # contains every construct it bans, and matching on its path breaks as soon
    # as the file is copied or moved.
    grep -q 'portability-lint-exempt' "$f" 2>/dev/null && continue
    # Ignore comment lines — the bans are documented in prose elsewhere.
    found=$(grep -nE "$pattern" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [[ -n "$found" ]]; then
      hits="${hits}${f#$ROOT/}:"$'\n'"$(printf '%s' "$found" | sed 's/^/      /')"$'\n'
    fi
  done <<< "$scripts"

  if [[ -z "$hits" ]]; then
    PASS=$((PASS + 1))
    echo "ok   no ${label}"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL ${label} found — not available on bash 3.2"
    echo "     use instead: ${advice}"
    printf '%s' "$hits"
  fi
done <<< "$BANNED"

# Every script must also still parse.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if /bin/bash -n "$f" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL ${f#$ROOT/} does not parse under /bin/bash"
    /bin/bash -n "$f" 2>&1 | sed 's/^/     /'
  fi
done <<< "$scripts"

echo
echo "portability: ${PASS} passed, ${FAIL} failed  ($(printf '%s' "$scripts" | grep -c . ) scripts scanned)"
[[ $FAIL -eq 0 ]]
