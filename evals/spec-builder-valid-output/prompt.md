---
runs: 1
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Write, Glob, Grep, Bash, Skill]
---

Write a swarm-spec for this change, and save it.

Webhook deliveries need to be idempotent: when the same event id arrives twice,
the pipeline should process it once and return the original response. State must
survive a process restart and hold for 24 hours. Don't touch the consumer side.
The public POST /webhooks contract must not change.

Do not interview me — I've given you what I know. Draft it, validate it, and
save it. Tell me where you saved it.
