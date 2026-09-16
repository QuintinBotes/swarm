#!/usr/bin/env bash
# run.sh — spec validator test suite.
# Every file under fixtures/valid/ must validate; every file under
# fixtures/invalid/ must be rejected. Exit 0 only if both hold.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${HERE}/../../lib/validate-spec.sh"
PASS=0
FAIL=0

for f in "${HERE}/fixtures/valid/"*.md; do
  [[ -e "$f" ]] || continue
  if bash "$VALIDATOR" "$f" > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "ok   valid/$(basename "$f")"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL valid/$(basename "$f") — expected VALID, got INVALID"
    bash "$VALIDATOR" "$f" 2>&1 | sed 's/^/       /'
  fi
done

for f in "${HERE}/fixtures/invalid/"*.md; do
  [[ -e "$f" ]] || continue
  if bash "$VALIDATOR" "$f" > /dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    echo "FAIL invalid/$(basename "$f") — expected INVALID, got VALID"
  else
    PASS=$((PASS + 1))
    echo "ok   invalid/$(basename "$f")"
  fi
done

echo
echo "spec-validation: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
