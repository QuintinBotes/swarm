#!/usr/bin/env bash
# spec-detect.sh — Detect whether a file carries swarm-spec frontmatter.
# Usage: spec-detect.sh /path/to/spec.md
# Emits structured JSON when the swarm-spec schema is present, `null` otherwise.
#
# A `null` result is not an error — it means the orchestrator falls back to
# freeform mode and asks the Architect to decompose prose instead.
set -euo pipefail

SPEC_FILE="${1:-}"

if [[ -z "$SPEC_FILE" || ! -f "$SPEC_FILE" ]]; then
  echo "null"
  exit 0
fi

_extract_frontmatter() {
  local file="$1"
  local in_front=0
  local found_open=0
  local result=""

  while IFS= read -r line; do
    if [[ $found_open -eq 0 ]]; then
      if [[ "$line" == "---" ]]; then
        found_open=1
        in_front=1
      else
        break
      fi
    elif [[ $in_front -eq 1 ]]; then
      if [[ "$line" == "---" ]]; then
        in_front=0
        break
      fi
      result+="${line}"$'\n'
    fi
  done < "$file"

  echo "$result"
}

_get_field() {
  local frontmatter="$1"
  local key="$2"
  echo "$frontmatter" | grep -m1 "^${key}:" | sed "s/^${key}:[[:space:]]*//" | tr -d '"' | tr -d "'" | tr -d '\r' || true
}

_json_str() {
  local val="$1"
  if [[ -z "$val" ]]; then
    echo "null"
  else
    echo "\"${val}\""
  fi
}

frontmatter=$(_extract_frontmatter "$SPEC_FILE")

if [[ -z "$frontmatter" ]]; then
  echo "null"
  exit 0
fi

schema=$(_get_field "$frontmatter" "schema")

if [[ "$schema" != "swarm-spec" ]]; then
  echo "null"
  exit 0
fi

schema_version=$(_get_field "$frontmatter" "schema_version")
spec_id=$(_get_field "$frontmatter" "spec_id")
status=$(_get_field "$frontmatter" "status")
owner=$(_get_field "$frontmatter" "owner")
area=$(_get_field "$frontmatter" "area")
[[ -z "$area" ]] && area=$(_get_field "$frontmatter" "domain")
kind=$(_get_field "$frontmatter" "kind")

printf '{"schema":%s,"schema_version":%s,"spec_id":%s,"status":%s,"owner":%s,"area":%s,"kind":%s}\n' \
  "$(_json_str "$schema")" \
  "$(_json_str "$schema_version")" \
  "$(_json_str "$spec_id")" \
  "$(_json_str "$status")" \
  "$(_json_str "$owner")" \
  "$(_json_str "$area")" \
  "$(_json_str "$kind")"
