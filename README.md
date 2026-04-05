# claude-foreman

OpenClaw skill for dispatching heavy-lift coding tasks to Claude CLI while keeping OpenClaw as orchestrator.

## What it includes
- `SKILL.md` usage + dispatch policy
- `profiles/` for `plan`, `implement`, `review`
- `scripts/dispatch.sh` with budget guardrails and structured logging
- `NOTES.md` for runtime learnings

## Install
Copy this folder into your OpenClaw workspace:

```bash
cp -r claude-foreman ~/.openclaw/workspace/skills/
```

Then follow the enforcement guidance in `SKILL.md`.

## Dispatch
```bash
scripts/dispatch.sh <profile> <target_dir> "<prompt>" [--model opus] [--worktree] [--force] [--max-turns N]
```

Profiles:
- `plan` (read-only analysis)
- `implement` (code edits/refactors)
- `review` (audit/review)

## Notes
This skill is intended for heavier coding lifts where native tool-call editing would be inefficient.
