---
type: llm
weight: 1
criteria: |
  The response states plainly that there is no active swarm run in this
  repository, and does not fabricate a run id, wave structure, task list, or
  progress dashboard.

  PASS: it reports no active run, and may suggest starting one.
  FAIL: it invents any run detail, or presents an empty dashboard as though a
  run existed, or is ambiguous about whether a run is in progress.
---
There is no .swarm/ directory here at all. Inventing a run would be worse than
saying nothing, because an operator would act on it.
