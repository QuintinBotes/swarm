#!/bin/bash
set -e
git init -q .
git config user.email eval@example.com
git config user.name eval
echo hello > README.md
git add -A && git commit -qm seed
