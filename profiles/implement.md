# Profile: implement

Full code editing capability. Claude CLI can read, write, and edit files,
and run common dev and shell commands.

## CLI Flags

```
--permission-mode acceptEdits
--allowedTools "Read,Glob,Grep,Edit,MultiEdit,Write,\
Bash(git:*),Bash(npm:*),Bash(npx:*),Bash(node:*),\
Bash(python:*),Bash(python3:*),Bash(pip:*),\
Bash(cargo:*),Bash(go:*),Bash(make:*),\
Bash(yarn:*),Bash(pnpm:*),Bash(bun:*),Bash(deno:*),\
Bash(pytest:*),Bash(jest:*),Bash(tsc:*),Bash(eslint:*),Bash(prettier:*),\
Bash(bash:*),Bash(sh:*),Bash(source:*),Bash(rg:*),\
Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*),\
Bash(test:*),Bash(env:*),Bash(wc:*),Bash(head:*),Bash(tail:*),\
Bash(sed:*),Bash(awk:*),Bash(cut:*),Bash(tr:*),Bash(sort:*),Bash(uniq:*),\
Bash(xargs:*),Bash(printf:*),Bash(echo:*),Bash(pwd:*),Bash(date:*),\
Bash(chmod:*),Bash(mkdir:*),Bash(cp:*),Bash(mv:*)"
--max-turns 30
--model opus
--output-format stream-json
--verbose
--no-session-persistence
```

Note: each `Bash(cmd:*)` is a separate allowlist entry. The combined
`Bash(a:*,b:*)` form is not valid syntax.

A final-output guardrail is automatically appended to every prompt so the run
ends with a written summary rather than a dangling tool call.

## When to Use

- Multi-file refactors and migrations
- New feature implementation
- Bulk edits (rename a symbol across a codebase, update imports)
- Workspace restructuring (reorganizing files, consolidating docs)
- Any edit where you'd estimate >50 lines of changes
- Shell-heavy skill or repo workflows that need common inspection utilities

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
