# Profile: implement

Full code editing capability. Claude CLI can read, write, and edit files,
and run common dev commands.

## CLI Flags

```
--permission-mode acceptEdits
--allowedTools "Read,Glob,Grep,Edit,Write,Bash(git:*,npm:*,npx:*,node:*,python:*,python3:*,pip:*,cargo:*,go:*,make:*,yarn:*,pnpm:*,bun:*,deno:*,pytest:*,jest:*,tsc:*,eslint:*,prettier:*)"
--max-turns 30
--model opus
--output-format json
--no-session-persistence
```

## When to Use

- Multi-file refactors and migrations
- New feature implementation
- Bulk edits (rename a symbol across a codebase, update imports)
- Workspace restructuring (reorganizing files, consolidating docs)
- Any edit where you'd estimate >50 lines of changes

## Prompt Tips

- Provide clear acceptance criteria: "The tests in tests/auth/ must still pass after changes"
- Scope the work: "Only modify files under src/api/. Do not touch src/core/"
- For large tasks, consider running `plan` first, then feeding the plan into `implement`
- If the repo has tests, ask Claude CLI to run them after making changes

## Worktree Recommendation

For repo work, prefer `--worktree` so changes are isolated. This lets you
review the diff before merging into the main branch.

For workspace self-edits, run in-place (no worktree) since the workspace
is not a typical git repo.
