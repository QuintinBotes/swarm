#!/usr/bin/env bash
# run.sh — wiring contract between the shell layer and the prompt layer.
#
# WHY THIS EXISTS.
#
# The orchestrator is a prompt. Its "code" is instructions in SKILL.md, which no
# test can execute. That creates a specific and quiet failure: a script ships,
# has its own passing suite, and is never actually called by anything. Every
# test is green and the capability does not exist.
#
# This happened here. lib/resume-state.sh had 31 passing tests and recorded wave
# completion correctly, but Phase 2 began "For each wave in order" and never
# read `next-wave` back. The state was recorded, reported, and discarded. An
# adversarial review caught it; no suite did.
#
# So these assertions are deliberately about REFERENCE, not behaviour: is every
# shipped script actually invoked, do the paths in the prompts resolve to real
# files, and are the verbs that matter — the ones where recording without
# consuming is indistinguishable from working — present on both sides.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
PROMPTS="${ROOT}/skills ${ROOT}/commands ${ROOT}/agents"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }

refs() { grep -rho "$1" $PROMPTS 2>/dev/null | head -1; }

# --- 1. Nothing ships unwired ------------------------------------------------
for f in "$ROOT"/lib/*.sh; do
  n=$(basename "$f")
  if [[ -n "$(refs "$n")" ]]; then
    ok "lib/${n} is referenced by the prompt layer"
  else
    bad "lib/${n} ships but nothing invokes it — a capability that does not exist"
  fi
done

# --- 2. Every path in a prompt resolves --------------------------------------
# Catches doc rot pointing at a script that was renamed or never existed.
missing=0
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  rel=${ref#*\}/}
  if [[ ! -e "${ROOT}/${rel}" ]]; then
    bad "prompts reference \${CLAUDE_PLUGIN_ROOT}/${rel}, which does not exist"
    missing=1
  fi
done <<< "$(grep -rho '\${CLAUDE_PLUGIN_ROOT}/[A-Za-z0-9_./-]*' $PROMPTS 2>/dev/null | sort -u)"
(( missing == 0 )) && ok "every \${CLAUDE_PLUGIN_ROOT} path in the prompts resolves"

# --- 3. Paired verbs ---------------------------------------------------------
# Each pair is a case where doing only the first half looks identical to
# working, from inside the test suite, while the capability is inert.
check_pair() {
  local label="$1" produce="$2" consume="$3" why="$4"
  local has_p has_c
  has_p=$(refs "$produce"); has_c=$(refs "$consume")
  if [[ -n "$has_p" && -n "$has_c" ]]; then
    ok "${label}: both '${produce}' and '${consume}' are wired"
  elif [[ -n "$has_p" ]]; then
    bad "${label}: '${produce}' is wired but '${consume}' is not — ${why}"
  else
    bad "${label}: '${produce}' is not wired at all"
  fi
}

check_pair "locking"  "run-lock.sh acquire"      "run-lock.sh release" \
  "a lock that is taken and never released strands the repository"
check_pair "resume"   "resume-state.sh record-wave" "resume-state.sh next-wave" \
  "recording progress nothing reads back means the operator is told the state and restarts anyway"

# --- 4. Gates that must run before the irreversible step ---------------------
skill="${ROOT}/skills/orchestrator/SKILL.md"

line_of() { grep -n "$1" "$skill" 2>/dev/null | head -1 | cut -d: -f1; }

integ=$(line_of 'check-integration.sh')
merge=$(line_of 'git merge --no-ff')
if [[ -n "$integ" && -n "$merge" ]] && (( integ < merge )); then
  ok "the integration check is documented before the merge, not after"
else
  bad "the integration check must appear before the merge step — a post-merge gate gates nothing"
fi

scope=$(line_of 'check-scope.sh')
if [[ -n "$scope" && -n "$merge" ]] && (( scope < merge )); then
  ok "the scope check is documented before the merge"
else
  bad "the scope check must appear before the merge step"
fi

# --- 5. The spec builder's two gates are distinct ----------------------------
spec_skill="${ROOT}/skills/swarm-spec/SKILL.md"
for needle in "validate-spec.sh" "score-spec.sh" "interrogator"; do
  if grep -q "$needle" "$spec_skill" 2>/dev/null; then
    ok "the spec builder wires ${needle}"
  else
    bad "the spec builder does not wire ${needle}"
  fi
done

# --- 6. Every agent definition is reachable ----------------------------------
for f in "$ROOT"/agents/*.md; do
  n=$(basename "$f" .md)
  if grep -rqi "$n" "$ROOT/skills" 2>/dev/null; then
    ok "agent '${n}' is dispatched by a skill"
  else
    bad "agent '${n}' ships but no skill dispatches it"
  fi
done

# --- defects found by a real end-to-end run ---------------------------------
# All three below passed every unit test and every eval case, and broke the
# first time /swarm was actually invoked. They are asserted here because none
# of them is reachable by testing a script in isolation.

SCHEMA="${ROOT}/skills/orchestrator/task-graph-schema.json"

# 1. A runId is built from the spec_id, and spec_id's own documented format is
#    <YYYY-MM-DD>_<kebab-name> — it contains an underscore. A runId pattern that
#    forbids underscores in the slug rejects every id the orchestrator produces.
pattern=$(jq -r '.properties.runId.pattern' "$SCHEMA" 2>/dev/null)
sample="2026-09-16T10-10-34_2026-09-16_string-helpers"
if printf '%s' "$sample" | grep -qE "$(printf '%s' "$pattern" | sed 's/\\d/[0-9]/g')"; then
  ok "the runId pattern accepts a runId built from a real spec_id"
else
  bad "the runId pattern rejects '${sample}', which is what building a runId from spec_id produces"
fi

# 2. Git stores a branch as a file at refs/heads/<name>, so swarm/<runId> cannot
#    exist while swarm/<runId>/<taskId> does — git refuses with 'cannot lock ref'.
#    The integration branch must not be a path prefix of the task branches.
feature=$(grep -o 'FEATURE_BRANCH="[^"]*"' "$skill" 2>/dev/null | head -1 | sed 's/.*="\(.*\)"/\1/')
if [[ "$feature" == "swarm/[runId]" ]]; then
  bad "the integration branch '${feature}' is a path prefix of swarm/[runId]/[taskId] — git cannot hold both"
elif [[ -n "$feature" ]]; then
  ok "the integration branch '${feature}' does not collide with the task branches"
else
  bad "no FEATURE_BRANCH found in the orchestrator"
fi

# 3. lib/check-integration.sh and lib/check-scope.sh resolve a base from the
#    graph's baseBranch. If the schema does not require it, the orchestrator
#    does not write it, and the pre-merge gate cannot run unattended.
if jq -e '.required | index("baseBranch")' "$SCHEMA" >/dev/null 2>&1; then
  ok "the schema requires baseBranch, so the pre-merge gates can resolve a base"
else
  bad "baseBranch is not required by the schema — check-integration --task-graph has nothing to read"
fi

if jq -e '.properties.waves.items.properties.tasks.items.properties.baseCommit' "$SCHEMA" >/dev/null 2>&1; then
  ok "the schema documents baseCommit, which check-scope.sh requires"
else
  bad "baseCommit is undocumented in the schema"
fi

echo
echo "wiring: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
