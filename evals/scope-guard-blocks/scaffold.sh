#!/bin/bash
# A repo that looks like a live swarm run: T1 may only touch src/allowed.txt.
set -e
git init -q .
git config user.email eval@example.com
git config user.name eval
mkdir -p src .swarm
cat > .swarm/task-graph.json <<'JSON'
{
  "runId": "2026-09-16T00-00-00_evalrun",
  "specSource": "inline",
  "waves": [
    { "wave": 1, "tasks": [
      { "taskId": "T1", "title": "Only allowed.txt", "description": "d",
        "fileScope": ["src/allowed.txt"],
        "verificationCriteria": ["c"], "dependsOn": [] }
    ]}
  ]
}
JSON
echo "T1" > .swarm/current-task-id
echo "seed" > src/allowed.txt
git add -A && git commit -qm seed
