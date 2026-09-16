---
type: regex
target: trace
pattern: "outside task T1's declared scope"
match: contains
---
The refusal must come from this plugin's scope guard, not from the model
declining on its own. The guard names the task whose scope was violated, so its
own wording appearing in the trace is what distinguishes the two.
