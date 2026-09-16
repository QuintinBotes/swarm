#!/usr/bin/env bash
# load-user-config.sh — Load optional user config from ~/.config/swarm/config.yaml
# Returns config as JSON. Safe defaults if the file is missing or malformed.
# Override the config path with SWARM_CONFIG=/path/to/config.yaml
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/swarm"
CONFIG_FILE="${SWARM_CONFIG:-${CONFIG_DIR}/config.yaml}"

# Defaults
DEFAULT_PARALLEL_AGENTS=4
DEFAULT_MODEL="sonnet"
DEFAULT_QA_ENABLED="true"
DEFAULT_REVIEWER_ENABLED="true"
DEFAULT_MERGE_STRATEGY="serialized"

_yaml_get() {
  local file="$1"
  local key="$2"
  grep -m1 "^${key}:" "$file" 2>/dev/null | sed "s/^${key}:[[:space:]]*//" | tr -d '"' | tr -d "'" | tr -d '\r' || true
}

_bool_val() {
  local val="$1"
  local default="$2"
  case "$val" in
    true|True|TRUE|yes|Yes|YES|1) echo "true" ;;
    false|False|FALSE|no|No|NO|0) echo "false" ;;
    *) echo "$default" ;;
  esac
}

_emit() {
  printf '{"parallel_agents":%d,"default_model":"%s","qa_enabled":%s,"reviewer_enabled":%s,"merge_strategy":"%s","config_source":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  _emit "$DEFAULT_PARALLEL_AGENTS" "$DEFAULT_MODEL" "$DEFAULT_QA_ENABLED" "$DEFAULT_REVIEWER_ENABLED" "$DEFAULT_MERGE_STRATEGY" "defaults"
  exit 0
fi

parallel_agents=$(_yaml_get "$CONFIG_FILE" "parallel_agents")
default_model=$(_yaml_get "$CONFIG_FILE" "default_model")
qa_enabled=$(_yaml_get "$CONFIG_FILE" "qa_enabled")
reviewer_enabled=$(_yaml_get "$CONFIG_FILE" "reviewer_enabled")
merge_strategy=$(_yaml_get "$CONFIG_FILE" "merge_strategy")

[[ -z "$parallel_agents" || ! "$parallel_agents" =~ ^[0-9]+$ ]] && parallel_agents="$DEFAULT_PARALLEL_AGENTS"
[[ -z "$default_model" ]] && default_model="$DEFAULT_MODEL"
[[ "$merge_strategy" != "serialized" && "$merge_strategy" != "octopus" ]] && merge_strategy="$DEFAULT_MERGE_STRATEGY"
qa_enabled=$(_bool_val "$qa_enabled" "$DEFAULT_QA_ENABLED")
reviewer_enabled=$(_bool_val "$reviewer_enabled" "$DEFAULT_REVIEWER_ENABLED")

_emit "$parallel_agents" "$default_model" "$qa_enabled" "$reviewer_enabled" "$merge_strategy" "$CONFIG_FILE"
