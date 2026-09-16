#!/usr/bin/env bash
# run.sh — readiness scorer tests.
# The scorer decides whether the wizard keeps grilling the user, so a false
# "ready" ends the interrogation early on a spec that cannot be implemented.
# Each case below asserts one signal fires on a spec that is fine except for
# that one flaw.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCORER="${HERE}/../../lib/score-spec.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# A spec that scores clean. Each test mutates exactly one part of it.
write_base() {
  cat > "$1" <<'MD'
---
schema: swarm-spec
schema_version: "2.0"
spec_id: 2026-09-16_base
kind: feature
status: Draft
owner: a@b.c
area: search
---

## Outcome

A query that matches no documents returns an empty result list with a 200 status
instead of a 404, so callers no longer special-case the empty case. Result
ordering is unchanged for queries that do match.

## Scope Boundaries

- `src/indexer/` — indexing behaviour is unchanged
- `src/auth/` — no change to who may issue a query

## Constraints

- Added latency must stay under 10 ms at p99 for 500 rps
- The response shape must not change for callers already handling matches
- Query text must never be written to logs or traces

## Prior Decisions

- Empty-result semantics follow the collection convention agreed in ADR-12
- Rejected returning 204, since callers already parse a body, see #443

## Task Breakdown

- [ ] T1 Return an empty collection rather than raising NotFound (files: src/search/handler.ts)
- [ ] T2 Cover the empty, single, and many cases (files: tests/search/empty.test.ts) (after: T1)

## Verification Criteria

- `[programmatic]` `npm run build` succeeds
- `[programmatic]` When a query matches nothing, the API shall return 200 with an empty list — covered by `empty query returns 200`
- `[programmatic]` When a query matches documents, ordering shall be unchanged — covered by `ordering unchanged`
- `[human]` Existing callers in the mobile client tolerate the new empty response
MD
}

dim() { bash "$SCORER" "$1" | sed -n "s/.*\"$2\": \"\([a-z-]*\)\".*/\1/p" | head -1; }
overall() { bash "$SCORER" "$1" | sed -n 's/.*"overall": "\([a-z-]*\)".*/\1/p' | head -1; }
finding_matches() { bash "$SCORER" "$1" | grep -qi "$2"; }

expect() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name — expected '$want', got '$got'"; fi
}
expect_finding() {
  local name="$1" file="$2" pattern="$3"
  if finding_matches "$file" "$pattern"; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name — no finding matching '$pattern'"; fi
}

# --- baseline ---------------------------------------------------------------
write_base "$TMP/base.md"
expect "a complete spec scores ready" "ready" "$(overall "$TMP/base.md")"

# --- outcome ----------------------------------------------------------------
write_base "$TMP/hedge.md"
perl -0pi -e 's/instead of a 404, so callers no longer special-case the empty case\./instead of a 404, and errors are handled gracefully./' "$TMP/hedge.md"
expect "hedge words weaken the outcome" "weak" "$(dim "$TMP/hedge.md" outcome)"
expect_finding "hedge word is named in the finding" "$TMP/hedge.md" "gracefully"

write_base "$TMP/thin.md"
perl -0pi -e 's/## Outcome\n\n.*?\n\n## Scope/## Outcome\n\nMake search better.\n\n## Scope/s' "$TMP/thin.md"
expect "a thin outcome is weak" "weak" "$(dim "$TMP/thin.md" outcome)"

# --- constraints ------------------------------------------------------------
write_base "$TMP/unquant.md"
perl -0pi -e 's/- Added latency must stay under 10 ms at p99 for 500 rps/- Latency should stay fast/' "$TMP/unquant.md"
expect "an unquantified performance constraint is weak" "weak" "$(dim "$TMP/unquant.md" constraints)"

write_base "$TMP/instr.md"
perl -0pi -e 's/- Query text must never be written to logs or traces/- Use an in-memory cache for results/' "$TMP/instr.md"
expect_finding "an instruction is flagged as not a constraint" "$TMP/instr.md" "instruction rather than a property"

# --- criteria ---------------------------------------------------------------
write_base "$TMP/generic.md"
perl -0pi -e 's/## Verification Criteria\n\n.*/## Verification Criteria\n\n- `[programmatic]` `npm run build` succeeds\n- `[programmatic]` `npm test` passes\n/s' "$TMP/generic.md"
expect "criteria that only run the suite are weak" "weak" "$(dim "$TMP/generic.md" criteria)"
expect_finding "the non-discriminating finding explains why" "$TMP/generic.md" "passed before the change"

write_base "$TMP/nocmd.md"
perl -0pi -e 's/- `\[programmatic\]` `npm run build` succeeds/- `[programmatic]` the project compiles/' "$TMP/nocmd.md"
expect_finding "a criterion with no command is flagged" "$TMP/nocmd.md" "name no command or test"

# --- decomposition ----------------------------------------------------------
write_base "$TMP/glob.md"
perl -0pi -e 's|\(files: src/search/handler\.ts\)|(files: src/search/*.ts)|' "$TMP/glob.md"
expect_finding "a glob scope is flagged" "$TMP/glob.md" "claim a glob"

write_base "$TMP/nodeps.md"
perl -0pi -e 's/ \(after: T1\)//' "$TMP/nodeps.md"
expect_finding "no dependency edges is questioned" "$TMP/nodeps.md" "no (after:) edges"

# --- boundaries and context -------------------------------------------------
write_base "$TMP/nobound.md"
perl -0pi -e 's/## Scope Boundaries\n\n.*?\n\n## Constraints/## Scope Boundaries\n\n\n## Constraints/s' "$TMP/nobound.md"
expect "missing boundaries is weak" "weak" "$(dim "$TMP/nobound.md" boundaries)"

write_base "$TMP/nocontext.md"
perl -0pi -e 's/## Prior Decisions\n\n.*?\n\n## Task Breakdown/## Prior Decisions\n\n- We talked\n\n## Task Breakdown/s' "$TMP/nocontext.md"
expect "thin context is weak" "weak" "$(dim "$TMP/nocontext.md" context)"

# --- ordering ---------------------------------------------------------------
write_base "$TMP/multi.md"
perl -0pi -e 's/instead of a 404, so callers no longer special-case the empty case\./instead of a 404, handled gracefully./' "$TMP/multi.md"
perl -0pi -e 's/## Prior Decisions\n\n.*?\n\n## Task Breakdown/## Prior Decisions\n\n- We talked\n\n## Task Breakdown/s' "$TMP/multi.md"
first=$(bash "$SCORER" "$TMP/multi.md" | tr -d ' \n' | sed -n 's/.*"interrogate_next":\["\([a-z]*\)".*/\1/p')
expect "outcome is interrogated before context" "outcome" "$first"

# --- robustness -------------------------------------------------------------
expect "a missing file does not crash the scorer" "" "$(overall "$TMP/nope.md")"
printf 'not a spec at all\n' > "$TMP/junk.md"
expect "junk input does not crash the scorer" "not-ready" "$(overall "$TMP/junk.md")"

echo
echo "scoring: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
