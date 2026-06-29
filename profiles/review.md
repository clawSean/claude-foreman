# Profile: review

Read-only code audit and review. Same permission mode as `plan` but adds URL
retrieval tools and the prompt framing targets quality assessment.

## CLI Flags

```
--permission-mode plan
--allowedTools "Read,Glob,Grep,WebFetch,Bash(git:*),Bash(curl:*),Bash(wget:*),Bash(ls:*),Bash(cat:*),Bash(wc:*),Bash(head:*),Bash(tail:*),Bash(env:*),Bash(pwd:*),Bash(date:*),Bash(find:*),Bash(echo:*)"
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

- PR review (diff analysis, quality checks)
- Security audit of a module or feature
- Performance review of hot paths
- Pre-merge review of a worktree branch created by `implement`
- Any read-only planning that involves public docs/URLs Claude should fetch

## Prompt Tips

- Point at the diff: "Review the changes between main and this branch. Focus on security and correctness."
- Ask for structured findings: "Return findings as a list with severity (critical/warning/info), file, line, and description"
- Be specific about what matters: "We care most about SQL injection and auth bypass. Style nits are low priority."
- For PR review, pass the branch context: "This PR adds rate limiting to the API. Review for correctness and edge cases."
