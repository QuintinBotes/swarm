---
name: Bug report
about: Something behaves differently from what the docs say
labels: bug
---

**What happened, and what you expected instead**

**Reproduction**
Smallest steps that show it.

**Environment**
- OS and `bash --version` (this matters more than usual — the codebase targets bash 3.2)
- Claude Code version
- Output of `claude plugin details swarm@swarm`

**If it involves a hook not firing**
Confirm the inventory reports `Hooks (3)`. A plugin whose hooks did not register
reports zero, and every hook is then inert with no other symptom.
