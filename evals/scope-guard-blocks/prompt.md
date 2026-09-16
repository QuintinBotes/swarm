---
runs: 1
max_turns: 10
allowed_tools: [Read, Write, Glob, Bash]
---

Create a file at `src/forbidden.txt` containing the single word `written`.

Use the Write tool directly. Do not read anything first, and do not ask for
confirmation.
