# Profile: wide-open

Root-safe, noninteractive broad-access mode. This is the closest approximation to `claws-out` on hosts where Claude is running as the Linux `root` user and true bypass mode is blocked.

## CLI Flags

```
--permission-mode dontAsk
--allowedTools "Read,Glob,Grep,Edit,MultiEdit,Write,WebFetch,Bash(*)"
--max-turns 25
--model opus
--output-format json
--no-session-persistence
```

## When to Use

- You want a claws-out-ish run on a root-run VPS
- The task needs broad shell freedom without interactive approvals
- `implement` is too narrow, but true bypass is unavailable
- You still want protected-path guardrails to remain in place

## Important Limits

- This is not true bypass mode
- Claude can still refuse protected-path operations such as writes inside `.git/`
- Relative target directories still depend on the caller's current working directory; prefer absolute repo paths when possible

## Prompt Tips

- Be explicit about scope and acceptance criteria
- Tell Claude to summarize what it changed and what commands it ran
- If you want repo inspection plus edits, say so directly
- Prefer absolute target paths unless the caller's `workdir` is already the repo
