#!/usr/bin/env bash
# run.sh — agent definition tests.
# Every file under agents/ must be a well-formed Claude Code subagent
# definition: closed frontmatter, the required fields, a model alias (never a
# pinned snapshot id), a name matching the filename, and — for the read-only
# agents — disallowedTools covering Edit and Write.
# bash 3.2 compatible.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${HERE}/../../agents"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; }

# Agents that must be read-only: no Edit, no Write.
is_readonly_agent() {
  case "$1" in
    architect|qa-security|reviewer|interrogator) return 0 ;;
    *) return 1 ;;
  esac
}

shopt -s nullglob
files=("${AGENTS_DIR}"/*.md)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  bad "agents directory has definitions" "no *.md files found under ${AGENTS_DIR}"
fi

for f in "${files[@]}"; do
  base="$(basename "$f")"
  stem="${base%.md}"

  # --- frontmatter opens and closes ----------------------------------------
  delim_count=$(grep -c '^---[[:space:]]*$' "$f")
  first_line=$(head -n1 "$f")
  if [[ "$first_line" == "---" && $delim_count -ge 2 ]]; then
    ok "$stem: frontmatter opens and closes"
    frontmatter=$(awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' "$f")
  else
    bad "$stem: frontmatter opens and closes" "expected file to start with '---' and close with a second '---'"
    frontmatter=""
  fi

  # --- name: present --------------------------------------------------------
  name_value=$(printf '%s\n' "$frontmatter" | sed -n 's/^name:[[:space:]]*//p' | head -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//')
  if [[ -n "$name_value" ]]; then
    ok "$stem: name: present"
  else
    bad "$stem: name: present" "no 'name:' field found in frontmatter"
  fi

  # --- description: present -------------------------------------------------
  desc_value=$(printf '%s\n' "$frontmatter" | sed -n 's/^description:[[:space:]]*//p' | head -1)
  if [[ -n "$desc_value" ]]; then
    ok "$stem: description: present"
  else
    bad "$stem: description: present" "no 'description:' field found in frontmatter"
  fi

  # --- model: is an alias, not a pinned snapshot id -------------------------
  model_value=$(printf '%s\n' "$frontmatter" | sed -n 's/^model:[[:space:]]*//p' | head -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//')
  case "$model_value" in
    opus|sonnet|haiku)
      ok "$stem: model: is an alias"
      ;;
    "")
      bad "$stem: model: is an alias" "no 'model:' field found in frontmatter"
      ;;
    *)
      bad "$stem: model: is an alias" "model: '${model_value}' is not one of opus/sonnet/haiku — pinned snapshot ids are banned"
      ;;
  esac

  # --- name: matches the filename -------------------------------------------
  if [[ "$name_value" == "$stem" ]]; then
    ok "$stem: name matches filename"
  else
    bad "$stem: name matches filename" "name: '${name_value}' does not match filename stem '${stem}'"
  fi

  # --- read-only agents declare disallowedTools including Edit and Write ---
  if is_readonly_agent "$stem"; then
    disallowed=$(awk '/^disallowedTools:/{f=1; next} /^[A-Za-z_-]+:/{f=0} f' "$f")
    has_edit=$(printf '%s\n' "$disallowed" | grep -c -- '-[[:space:]]*Edit[[:space:]]*$')
    has_write=$(printf '%s\n' "$disallowed" | grep -c -- '-[[:space:]]*Write[[:space:]]*$')
    if [[ $has_edit -gt 0 && $has_write -gt 0 ]]; then
      ok "$stem: read-only agent disallows Edit and Write"
    else
      bad "$stem: read-only agent disallows Edit and Write" "expected disallowedTools to list both Edit and Write for '${stem}'"
    fi
  fi
done

echo
echo "agents: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
