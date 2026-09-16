#!/bin/bash
# A small, real Node repo so detect-stack.sh has something true to find.
set -e
git init -q .
git config user.email eval@example.com
git config user.name eval
mkdir -p src/webhooks tests
cat > package.json <<'JSON'
{ "name": "demo", "version": "1.0.0",
  "scripts": { "build": "tsc", "test": "vitest run", "lint": "eslint ." } }
JSON
cat > src/webhooks/pipeline.ts <<'TS'
export function deliver(event: { id: string }) { return send(event); }
function send(e: { id: string }) { return e.id; }
TS
echo "node_modules" > .gitignore
git add -A && git commit -qm seed
