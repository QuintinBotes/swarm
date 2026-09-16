## What this changes, and why

## How it was verified

- [ ] `bash tests/run-all.sh` passes
- [ ] `claude plugin validate . --strict` passes
- [ ] `shellcheck --severity=warning` is clean
- [ ] Any new or changed test was confirmed to fail before the fix

If you changed a hook: confirm `claude plugin details` still reports three
hooks against a real install.

## Anything you deliberately did not claim as solved
