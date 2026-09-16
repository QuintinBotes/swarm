---
description: "Show the state of a running or completed swarm — task progress, QA results, worktrees"
allowed-tools: Read, Bash, Glob, Grep
---

Do not invoke any skill. Run these checks directly and report.

## 1. Is a swarm active?

```bash
if [ -f .swarm/task-graph.json ]; then echo "SWARM_ACTIVE"; else echo "NO_SWARM"; fi
```

If not active, say "No active swarm. Run `/swarm <spec>` to start one." and stop.

## 2. Read the graph

Read `.swarm/task-graph.json`; extract every task with its wave.

## 3. Resolve each task's state

- **QA:** `.swarm/qa-status/<taskId>.passed` or `.swarm/qa-status/<taskId>.pending`
- **Worktree:** `git worktree list`
- **Progress:** commits ahead of the base branch on each task branch

A task with neither QA flag and no worktree has not started. A task with a
worktree and no flags is running.

## 4. Print the dashboard

```
  ╔═══════════════════════════════════════════╗
  ║              SWARM STATUS                 ║
  ╚═══════════════════════════════════════════╝

  Run ID:  [runId]
  Spec:    [specSource]
  Waves:   [N]

  ┌─── Wave 1 ────────────────────────────────┐
  │ T1  [title]            ✅ QA passed        │
  │ T2  [title]            ⏳ running          │
  │ T3  [title]            ❌ QA failed        │
  └───────────────────────────────────────────┘

  ┌─── Wave 2 ────────────────────────────────┐
  │ T4  [title]            ⏸  waiting on T1    │
  └───────────────────────────────────────────┘

  Worktrees: [N active]

  Legend: ✅ passed  ⏳ running  ❌ failed  ⏸ waiting  ○ not started
```

Use real data from the task graph. If the user asks for detail, show each task's
file scope and verification criteria.
