---
type: regex
target: trace
pattern: "outside task T1's declared scope"
match: not_contains
---
src/allowed.txt IS in T1's file scope. The guard must let it through.

This case exists because case scope-guard-blocks cannot distinguish a correct
guard from one that refuses every write — both score 1.00 there. A guard is only
working if it blocks the right things AND permits the right things.
