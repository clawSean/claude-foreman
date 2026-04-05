# Profile: review

Read-only code audit and review. Same tool access as `plan` but the prompt
framing targets quality assessment rather than planning.

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

- PR review (diff analysis, quality checks)
- Security audit of a module or feature
- Performance review of hot paths
- Pre-merge review of a worktree branch created by `implement`

## Prompt Tips

- Point at the diff: "Review the changes between main and this branch. Focus on security and correctness."
- Ask for structured findings: "Return findings as a list with severity (critical/warning/info), file, line, and description"
- Be specific about what matters: "We care most about SQL injection and auth bypass. Style nits are low priority."
- For PR review, pass the branch context: "This PR adds rate limiting to the API. Review for correctness and edge cases."
