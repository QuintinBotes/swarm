# Eval suite

`tests/` covers the shell layer. It cannot cover the prompt layer — the
orchestrator and the spec builder are instructions, and no bash suite can
execute an instruction. This directory covers that gap.

```bash
claude plugin eval . --trust-plugin --scaffold \
  --allow-tools Write,Edit,Bash --runs 1 --no-publish
```

Each case runs twice: once with the plugin loaded and once without. The **Δ**
between those arms is the point — it isolates what the plugin actually causes
from what a capable model would have done anyway.

## The cases

| case | what it establishes | expected Δ |
|---|---|---|
| `scope-guard-blocks` | an out-of-scope write is refused at runtime | **positive** |
| `scope-guard-allows` | an in-scope write is *not* refused | **zero, by design** |
| `spec-builder-valid-output` | `/spec` runs both gates and saves a spec that validates | **positive** |
| `status-no-active-run` | status reports no run rather than inventing one | **zero, by design** |

**A zero Δ is not a failure.** Two of these are non-regression checks, not
capability checks. Without the plugin there is no guard, so an in-scope write
succeeds in both arms and Δ is necessarily zero — what matters is that the
*with* arm scores 1.00. Reading Δ as the only signal would mark a working
safety property as worthless.

## Why the pair matters

`scope-guard-blocks` on its own proves nothing useful. A guard that refuses
**every** write scores a perfect 1.00 on it. `scope-guard-allows` is what makes
the pair meaningful: same scaffold, a path that *is* in scope, asserting the
guard's denial message is absent. A guard works only if it blocks the right
things and permits the right things.

`scope-guard-blocks` also greps the live trace for the guard's own wording
(`outside task T1's declared scope`). Without it, a case would pass whenever
the model simply chose not to write — which is a different thing from being
stopped. The without-plugin arm confirms this discriminates: the pattern is
absent there, and the file gets written.

## Cost, and why this is not a CI gate

Every run is a real model call. The suite costs roughly $2 and takes about five
minutes. It is a **pre-release gate, run by hand**, not a per-pull-request
check. `tests/run-all.sh` and `claude plugin validate` are the free, offline
checks that run in CI; this is the one you run before tagging a release.

Record the result in the pull request when you run it.
