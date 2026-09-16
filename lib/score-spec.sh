#!/usr/bin/env bash
# score-spec.sh — Measure how ready a spec is for an agent to implement.
#
# Usage: score-spec.sh <spec.md>
# Emits JSON: per-dimension verdicts plus concrete weak spots to interrogate.
#
# This is deliberately NOT a quality judgement. It is a set of mechanical
# signals that a language model cannot talk itself out of — hedge words are
# present or they are not, a constraint has a number or it does not. The
# interrogation protocol turns these signals into questions; the model supplies
# the judgement the signals cannot.
#
# Exit code is always 0. A spec is not "wrong" for scoring badly; it is unfinished.
# bash 3.2 compatible.
set -uo pipefail

SPEC="${1:-}"
if [[ -z "$SPEC" || ! -f "$SPEC" ]]; then
  echo '{"error":"spec file not found"}'
  exit 0
fi

body=$(awk 'BEGIN{n=0} /^---$/ {n++; next} n>=2 {print}' "$SPEC")

section() {
  echo "$body" | awk -v s="$1" '
    $0 ~ "^## " s "[[:space:]]*$" {f=1; next}
    /^## / {f=0}
    f {print}'
}

outcome=$(section "Outcome")
boundaries=$(section "Scope Boundaries")
constraints=$(section "Constraints")
decisions=$(section "Prior Decisions")
[[ -z "$decisions" ]] && decisions=$(section "Root Cause")
tasks=$(echo "$body" | awk '/^## Task Breakdown/{f=1;next} /^## /{f=0} f && /^- \[[ xX]\]/ {print}')
criteria=$(echo "$body" | awk '/^## Verification Criteria/{f=1;next} /^## /{f=0} f && /^- /{print}')

# Hedges: language that reads as a requirement but commits to nothing. An agent
# will satisfy every one of these trivially and incorrectly.
HEDGES='appropriate|appropriately|properly|correctly|as needed|as necessary|if needed|where possible|reasonable|reasonably|sensible|gracefully|robust|efficient|efficiently|performant|scalable|user-friendly|clean|simple|good|better|improved|optimi[sz]ed|etc\.|and so on|various|several|some sort of|something like|handle(s)? (it|this|that)|make sure|ensure that it works'

# Implementation leakage in an Outcome: describes mechanism, not observable result.
LEAKAGE='\bclass\b|\binterface\b|\bmethod\b|\bfunction\b|\bfield\b|\bcolumn\b|\btable\b|\bendpoint\b|refactor|implement(s|ed|ation)?\b|\bvia\b|\bby calling\b|\busing (a|an|the)\b'

WEAK=""      # newline-separated "dimension|detail" records
add_weak()  { WEAK="${WEAK}${1}|${2}"$'\n'; }

_jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g'; }

# --- 1. Outcome ------------------------------------------------------------
outcome_words=$(printf '%s' "$outcome" | wc -w | tr -d ' ')
outcome_hedges=$(printf '%s' "$outcome" | grep -ioE "$HEDGES" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
outcome_leak=$(printf '%s' "$outcome" | grep -ioE "$LEAKAGE" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')

outcome_verdict="ready"
if (( outcome_words < 20 )); then
  outcome_verdict="weak"
  add_weak "outcome" "Only ${outcome_words} words. Too thin to distinguish a correct implementation from a plausible wrong one."
fi
if [[ -n "$outcome_hedges" ]]; then
  outcome_verdict="weak"
  add_weak "outcome" "Hedge words with no committed meaning: ${outcome_hedges}"
fi
if [[ -n "$outcome_leak" ]]; then
  [[ "$outcome_verdict" == "ready" ]] && outcome_verdict="adequate"
  add_weak "outcome" "Reads as mechanism rather than observable result: ${outcome_leak}"
fi

# --- 2. Scope boundaries ----------------------------------------------------
boundary_count=$(printf '%s' "$boundaries" | grep -c '^- ')
boundary_paths=$(printf '%s' "$boundaries" | grep -c '`')
boundary_verdict="ready"
if (( boundary_count == 0 )); then
  boundary_verdict="weak"
  add_weak "boundaries" "No boundaries declared. Nothing stops an agent editing adjacent code."
elif (( boundary_count < 2 )); then
  boundary_verdict="adequate"
  add_weak "boundaries" "Only one boundary. Name the adjacent areas a reasonable agent would drift into."
fi
if (( boundary_count > 0 && boundary_paths == 0 )); then
  boundary_verdict="adequate"
  add_weak "boundaries" "No boundary names a concrete path or system — an abstract exclusion is unenforceable."
fi

# --- 3. Constraints ---------------------------------------------------------
constraint_count=$(printf '%s' "$constraints" | grep -c '^- ')
constraint_hedges=$(printf '%s' "$constraints" | grep -ioE "$HEDGES" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
# A constraint that talks about speed, size, or volume but carries no number.
perf_lines=$(printf '%s' "$constraints" | grep -icE 'latency|throughput|p9[0-9]|perform|fast|slow|memory|size|volume|rate|concurren|timeout|duration')
perf_numbers=$(printf '%s' "$constraints" | grep -cE 'latency|throughput|p9[0-9]|perform|fast|slow|memory|size|volume|rate|concurren|timeout|duration' 2>/dev/null)
quantified=$(printf '%s' "$constraints" | grep -cE '[0-9]+[[:space:]]*(ms|s\b|sec|second|minute|hour|day|%|rps|qps|req|MB|GB|KB|kb|mb|gb)')
# Instructions masquerading as constraints.
instructions=$(printf '%s' "$constraints" | grep -inE '^- (use|add|create|build|write|implement|call|store (it )?in|put (it )?in)\b' | head -3 | tr '\n' ';' | sed 's/;$//')

constraint_verdict="ready"
if (( constraint_count == 0 )); then
  constraint_verdict="weak"
  add_weak "constraints" "No constraints. Every non-functional requirement is unstated and will be dropped."
elif (( constraint_count < 3 )); then
  constraint_verdict="adequate"
  add_weak "constraints" "Only ${constraint_count} constraint(s). Categories usually missing: compatibility, data handling, security, tenancy, operational limits."
fi
if [[ -n "$constraint_hedges" ]]; then
  constraint_verdict="weak"
  add_weak "constraints" "Unfalsifiable wording: ${constraint_hedges}"
fi
if (( perf_lines > 0 && quantified == 0 )); then
  constraint_verdict="weak"
  add_weak "constraints" "Mentions performance or capacity but states no number or unit. An agent cannot tell whether it met it."
fi
if [[ -n "$instructions" ]]; then
  [[ "$constraint_verdict" == "ready" ]] && constraint_verdict="adequate"
  add_weak "constraints" "Written as an instruction rather than a property — it will be obeyed even where it is wrong: ${instructions}"
fi

# --- 4. Context (Prior Decisions / Root Cause) ------------------------------
context_words=$(printf '%s' "$decisions" | wc -w | tr -d ' ')
context_refs=$(printf '%s' "$decisions" | grep -cE '[A-Z]{2,}-[0-9]+|ADR|#[0-9]+|http')
context_verdict="ready"
if (( context_words < 15 )); then
  context_verdict="weak"
  add_weak "context" "Almost no context (${context_words} words). Parallel agents will each independently re-decide whatever was left unsaid."
elif (( context_refs == 0 )); then
  context_verdict="adequate"
  add_weak "context" "No references to an issue, ADR, or thread. Decisions without provenance get relitigated."
fi

# --- 5. Decomposition -------------------------------------------------------
task_count=$(printf '%s' "$tasks" | grep -c '^- ')
file_count=$(printf '%s' "$tasks" | sed -n 's/.*(files:\([^)]*\)).*/\1/p' | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -vc '^$')
dep_count=$(printf '%s' "$tasks" | grep -c '(after:')
glob_count=$(printf '%s' "$tasks" | sed -n 's/.*(files:\([^)]*\)).*/\1/p' | grep -c '\*')
thin_tasks=$(printf '%s' "$tasks" | awk '{ if (length($0) < 55) print }' | wc -l | tr -d ' ')

decomposition_verdict="ready"
if (( task_count == 0 )); then
  decomposition_verdict="weak"
  add_weak "decomposition" "No tasks."
elif (( task_count == 1 )); then
  decomposition_verdict="adequate"
  add_weak "decomposition" "One task. There is no parallelism here — a single session is cheaper and faster than a swarm."
fi
if (( task_count > 1 && dep_count == 0 )); then
  decomposition_verdict="adequate"
  add_weak "decomposition" "${task_count} tasks and no (after:) edges at all. Genuinely independent work is rare; check whether one task really consumes another's output."
fi
if (( task_count > 0 && file_count > 0 && file_count < task_count )); then
  decomposition_verdict="weak"
  add_weak "decomposition" "Fewer distinct files (${file_count}) than tasks (${task_count}). The cut is almost certainly in the wrong place."
fi
if (( glob_count > 0 )); then
  [[ "$decomposition_verdict" == "ready" ]] && decomposition_verdict="adequate"
  add_weak "decomposition" "${glob_count} task(s) claim a glob. A glob claims files that do not exist yet and is the usual source of a silent scope overlap."
fi
if (( thin_tasks > 0 )); then
  [[ "$decomposition_verdict" == "ready" ]] && decomposition_verdict="adequate"
  add_weak "decomposition" "${thin_tasks} task(s) have a title too short to brief an agent that cannot ask you what it means."
fi

# --- 6. Verification criteria -----------------------------------------------
crit_total=$(printf '%s' "$criteria" | grep -c '^- ')
crit_prog=$(printf '%s' "$criteria" | grep -c '\[programmatic\]')
crit_human=$(printf '%s' "$criteria" | grep -c '\[human\]')
# The tag itself is usually backticked, so it has to be stripped before looking
# for a command — otherwise every criterion appears to name one.
crit_cmd=$(printf '%s' "$criteria" | grep '\[programmatic\]' \
  | sed 's/`\{0,1\}\[programmatic\]`\{0,1\}//' | grep -c '`')
crit_ears=$(printf '%s' "$criteria" | grep -ciE 'when .*(shall|must)|if .*(shall|must)|while .*(shall|must)')
crit_hedges=$(printf '%s' "$criteria" | grep -ioE "$HEDGES" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
# A criterion discriminates if it names what specifically must be true — a
# trigger-and-response clause, or the test that covers it. A criterion that only
# invokes the build or the whole suite was equally true before the change, so it
# gates nothing on its own. Both kinds belong in a spec; a spec made entirely of
# the second kind has no gate.
crit_discriminating=$(printf '%s' "$criteria" | grep '\[programmatic\]' \
  | grep -ciE 'covered by|\bshall\b|\bmust\b|\bwhen\b|\bgiven\b')
crit_generic=$((crit_prog - crit_discriminating))

criteria_verdict="ready"
if (( crit_prog == 0 )); then
  criteria_verdict="weak"
  add_weak "criteria" "No [programmatic] criteria. Nothing gates the run; QA becomes one model asking another whether the code looks nice."
fi
if (( crit_prog > 0 && crit_cmd < crit_prog )); then
  criteria_verdict="weak"
  add_weak "criteria" "$((crit_prog - crit_cmd)) programmatic criterion(s) name no command or test. An agent cannot run prose."
fi
if (( crit_prog > 0 && crit_discriminating == 0 )); then
  criteria_verdict="weak"
  add_weak "criteria" "All ${crit_prog} programmatic criteria just invoke the build or the whole suite — every one of them passed before the change too. Nothing here distinguishes done from not-done."
elif (( crit_prog > 2 && crit_discriminating == 1 )); then
  [[ "$criteria_verdict" == "ready" ]] && criteria_verdict="adequate"
  add_weak "criteria" "Only 1 of ${crit_prog} programmatic criteria actually discriminates; the rest are generic build and test invocations."
fi
if (( crit_ears == 0 && crit_prog > 0 )); then
  [[ "$criteria_verdict" == "ready" ]] && criteria_verdict="adequate"
  add_weak "criteria" "No behavioural criterion in 'When X, the system shall Y' form. Without a named trigger and response there is no test to write."
fi
if [[ -n "$crit_hedges" ]]; then
  criteria_verdict="weak"
  add_weak "criteria" "Criteria contain unfalsifiable wording: ${crit_hedges}"
fi
if (( crit_human == 0 )); then
  [[ "$criteria_verdict" == "ready" ]] && criteria_verdict="adequate"
  add_weak "criteria" "No [human] criteria. Either nothing needs judgement, which is unusual, or the judgement is being left implicit."
fi

# --- Aggregate --------------------------------------------------------------
weak_n=0; adequate_n=0
for v in "$outcome_verdict" "$boundary_verdict" "$constraint_verdict" "$context_verdict" "$decomposition_verdict" "$criteria_verdict"; do
  [[ "$v" == "weak" ]]     && weak_n=$((weak_n + 1))
  [[ "$v" == "adequate" ]] && adequate_n=$((adequate_n + 1))
done

if   (( weak_n > 0 ));     then overall="not-ready"
elif (( adequate_n > 1 )); then overall="borderline"
else                            overall="ready"
fi

# Blast radius order: a weak Outcome corrupts everything downstream, so it is
# always interrogated first.
focus=""
for pair in "outcome:$outcome_verdict" "criteria:$criteria_verdict" "decomposition:$decomposition_verdict" \
            "constraints:$constraint_verdict" "boundaries:$boundary_verdict" "context:$context_verdict"; do
  d="${pair%%:*}"; v="${pair##*:}"
  [[ "$v" == "weak" ]] && focus="${focus}${d} "
done
if [[ -z "$focus" ]]; then
  for pair in "outcome:$outcome_verdict" "criteria:$criteria_verdict" "decomposition:$decomposition_verdict" \
              "constraints:$constraint_verdict" "boundaries:$boundary_verdict" "context:$context_verdict"; do
    d="${pair%%:*}"; v="${pair##*:}"
    [[ "$v" == "adequate" ]] && focus="${focus}${d} "
  done
fi
focus="${focus% }"

focus_json="["
for f in $focus; do focus_json="${focus_json}\"${f}\","; done
focus_json="${focus_json%,}]"

weak_json="["
while IFS= read -r rec; do
  [[ -z "$rec" ]] && continue
  dim="${rec%%|*}"; detail="${rec#*|}"
  weak_json="${weak_json}{\"dimension\":\"${dim}\",\"finding\":\"$(_jesc "$detail")\"},"
done <<< "$WEAK"
weak_json="${weak_json%,}]"

cat <<JSON
{
  "spec": "$(_jesc "$SPEC")",
  "overall": "${overall}",
  "dimensions": {
    "outcome": "${outcome_verdict}",
    "boundaries": "${boundary_verdict}",
    "constraints": "${constraint_verdict}",
    "context": "${context_verdict}",
    "decomposition": "${decomposition_verdict}",
    "criteria": "${criteria_verdict}"
  },
  "counts": {
    "outcome_words": ${outcome_words},
    "boundaries": ${boundary_count},
    "constraints": ${constraint_count},
    "tasks": ${task_count},
    "distinct_files": ${file_count},
    "dependency_edges": ${dep_count},
    "criteria_programmatic": ${crit_prog},
    "criteria_human": ${crit_human},
    "criteria_ears": ${crit_ears},
    "criteria_discriminating": ${crit_discriminating}
  },
  "interrogate_next": ${focus_json},
  "findings": ${weak_json}
}
JSON
