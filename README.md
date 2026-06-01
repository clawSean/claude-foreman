# claude-foreman

OpenClaw skill for dispatching bounded planning, review, and implementation jobs to Claude CLI while keeping OpenClaw (a multi-channel agent gateway/orchestrator) in charge.

Claude Foreman is useful when the main agent should keep ownership of the conversation, memory, project state, and user intent, but a slice of work benefits from Claude's separate context window and editing/review strengths. The orchestrator decides what to delegate; Claude executes the packet; the orchestrator reviews the result and reports back.

This is not a replacement model route. It is a repeatable dispatch harness: permission profiles, cost logging, git-safe review flow, and final-summary discipline around Claude CLI.

## When it shines

- Second-opinion architecture and code review without distracting the main agent
- Large edits or broad codebase inspection that would chew through the main context
- Final-polish and readability passes that benefit from Opus's stronger judgment
- Isolated implementation packets with a git snapshot/diff to review afterward
- Keeping a responsive orchestrator in chat while heavier work runs off to the side

## What it includes
- `SKILL.md` usage + dispatch policy
- `profiles/` for `plan`, `implement`, `review`, `wide-open`, `claws-out` (legacy alias: `unsafe`)
- `scripts/dispatch.sh` with budget guardrails and structured logging
- `NOTES.md` for runtime learnings

## Quickstart

```bash
scripts/dispatch.sh review /path/to/repo \
  "Review the current diff. Focus on correctness, risk, and missing tests."
```

Expected result: Foreman prints the selected profile/model, runs Claude CLI, logs cost/turn metadata, and returns Claude's final summary. For write-profile runs, review the git diff before merging or copying changes forward.

## Install
Copy this folder into your OpenClaw workspace:

```bash
cp -r claude-foreman ~/.openclaw/workspace/skills/
```

Then follow the enforcement guidance in `SKILL.md`.

## Dispatch
```bash
scripts/dispatch.sh <profile> <target_dir> "<prompt>" [--model <alias>] [--worktree] [--force] [--max-turns N]
```

Profiles:
- `plan` (read-only analysis)
- `implement` (code edits/refactors)
- `review` (audit/review + remote read helpers)
- `wide-open` (root-safe, noninteractive broad-access mode)
- `claws-out` (🦞 true bypass mode; trusted non-root sandbox targets only)

Default model is **Opus** across profiles. Use `--model sonnet` as an explicit lighter-cost escape hatch.

Compatibility: `unsafe` is still accepted as a legacy alias for `claws-out`. `root-wide` and `claws-wide` are accepted as aliases for `wide-open`.

## Notes
This skill is intended for heavier or higher-stakes work where native tool-call editing would be inefficient, context-expensive, or better handled by a separated reviewer/implementer.
