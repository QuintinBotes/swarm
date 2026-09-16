#!/usr/bin/env bash
# run-all.sh — every test suite in this repo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS=0

for suite in "${HERE}"/*/run.sh; do
  [[ -e "$suite" ]] || continue
  echo "=== $(basename "$(dirname "$suite")") ==="
  bash "$suite" || STATUS=1
  echo
done

if [[ $STATUS -eq 0 ]]; then echo "ALL SUITES PASSED"; else echo "SUITE FAILURES"; fi
exit $STATUS
