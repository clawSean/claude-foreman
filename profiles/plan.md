# Profile: plan

Read-only analysis and planning. Claude CLI can explore the codebase but cannot
modify any files.

## CLI Flags

```
--permission-mode plan
--allowedTools "Read,Glob,Grep,Bash(git:*),Bash(ls:*),Bash(cat:*),Bash(wc:*),Bash(head:*),Bash(tail:*),Bash(env:*),Bash(pwd:*),Bash(date:*),Bash(find:*),Bash(echo:*)"
--max-turns 15
--model opus
--output-format stream-json
--verbose
--no-session-persistence
```

Note: each `Bash(cmd:*)` is a separate allowlist entry. The combined
`Bash(a:*,b:*)` form is not valid syntax.

A final-output guardrail is automatically appended to every prompt so the run
ends with a written summary rather than a dangling tool call.

Optional extra filesystem roots can be exposed with `FOREMAN_EXTRA_ADD_DIRS`,
for example `FOREMAN_EXTRA_ADD_DIRS="/Users/me:/opt/homebrew:/tmp"`.

## When to Use

- Architecture analysis before a refactor
- Understanding how a system works before proposing changes
- Estimating scope and listing affected files
- Generating implementation plans for the `implement` profile to execute

## Prompt Tips

- Ask for structured output: "List all affected files with a one-line summary of what changes each needs"
- Ask for risk assessment: "Flag anything that could break existing tests or public APIs"
- Be specific about scope: "Only analyze src/auth/, ignore test files"
- Use `review` instead of `plan` when the prompt includes public URLs Claude should fetch
