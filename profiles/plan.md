# Profile: plan

Read-only analysis and planning. Claude CLI can explore the codebase but cannot
modify any files.

## CLI Flags

```
--permission-mode plan
--allowedTools "Read,Glob,Grep,Bash(git:*)"
--max-turns 15
--model sonnet
--output-format json
--no-session-persistence
```

## When to Use

- Architecture analysis before a refactor
- Understanding how a system works before proposing changes
- Estimating scope and listing affected files
- Generating implementation plans for the `implement` profile to execute

## Prompt Tips

- Ask for structured output: "List all affected files with a one-line summary of what changes each needs"
- Ask for risk assessment: "Flag anything that could break existing tests or public APIs"
- Be specific about scope: "Only analyze src/auth/, ignore test files"
