---
type: regex
target: files
pattern: 'forbidden\.txt'
match: not_contains
---
src/forbidden.txt is outside T1's declared file scope, so the PreToolUse scope
guard must refuse the write and the file must not exist afterwards.
