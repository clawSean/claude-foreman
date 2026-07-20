---
name: "claude-foreman"
description: "Dispatch bounded planning, review, and implementation jobs to Claude CLI for isolated execution while the main agent remains orchestrator. Delegate generously: multi-file refactors, edits over ~50 lines, codebase exploration plus implementation, deep code reviews, second opinions, parallel review lanes, or any task needing more than 3-4 sequential tool calls. User-requested Foreman defaults to the best model and max thinking. Do NOT use for quick one-line fixes, simple config changes, or short lookups."
---

# Claude Foreman

Delegate bounded work packets to Claude CLI while the main agent keeps ownership
of the conversation, memory, project state, and user intent. You orchestrate:
decide what to delegate, choose a permission profile, review the result, and
report back. Claude CLI executes the packet in isolation.

Claude Foreman is not a replacement model route. It is a repeatable dispatch
harness around Claude CLI and ACPX: permission profiles, cost logging, git-safe
review flow, and final-summary discipline.

## Default Stance

Use Claude Foreman generously when it would improve judgment, coverage, or
parallelism. If you are already considering Foreman, bias toward using it.

Be generous across:

- **Frequency:** use it for more than only huge refactors. It is also useful for
  reviews, option generation, architecture checks, and sanity passes.
- **Concurrency:** run multiple lanes when independent perspectives would help,
  especially product vs. architecture vs. red-team reviews.
- **Model quality:** default to Opus for substantive planning/review/editing.
  Use lighter models only when cost/speed clearly matters more than depth.
- **Thinking mode:** use high/max thinking for complex, ambiguous, or
  user-requested Foreman work.
- **Separation:** let Foreman inspect or reason in isolation while the main agent
  keeps user context, orchestration, and final decisions.

When JPop explicitly asks to use Foreman, default to the best available Claude
model and typically the highest thinking/effort mode. Do not choose fast mode or
Haiku for a user-requested Foreman run unless JPop explicitly asks for a cheap or
fast pass.

## Use It When

- A second opinion or review pass would improve confidence.
- A task benefits from two or more independent perspectives.
- Codebase or workspace exploration will take several tool calls.
- The work touches multiple files, more than roughly 50 lines, or shared behavior.
- The task needs architecture analysis, code review, red-team pressure, or product
  critique.
- The main agent should remain responsive while heavier work runs off-thread.
- You want implementation or review separated from orchestration.

Keep work native for one-line fixes, tiny lookups, and simple answers that do not
benefit from isolated Claude judgment.

## Optional: As a Ralph Executor

Claude Foreman can execute a single heavy slice inside a Ralph Wiggum loop.

- Ralph owns iteration, state, verification, and what counts as done.
- Foreman executes the selected slice with the narrowest useful profile.
- Offer this pairing when the user asks for Ralph/Foreman and the task fits
  small-loop iteration but one slice is too large for inline work.
- Return compact evidence back to the Ralph loop: files changed, diff summary,
  checks run, pass/fail, and blockers.
- Do not let Foreman silently expand into an open-ended loop. If more iteration
  is needed, hand control back to Ralph.

## Profiles

Five execution profiles control what Claude CLI can do:

| Profile | Use For |
|---|---|
| `plan` | Analysis, architecture, planning, template suggestions, read-only local work |
| `implement` | Code edits, file creation, refactors |
| `review` | Code audit, PR review, quality checks, or planning that needs public URL fetches |
| `wide-open` | Root-safe, noninteractive broad-access mode using allowlists instead of bypass |
| `claws-out` | Full-access bypass mode for trusted/sandboxed non-root environments only |

`plan` is read-only but has no web-fetch tools. Use `review` when the prompt
includes public docs or URLs that Claude should fetch. Use `implement` for edits.
On Linux hosts running as root, `claws-out` is blocked by Claude; use
`wide-open` or `implement` instead.

## Model And Effort Defaults

- Default model is `opus` across profiles.
- For user-requested Foreman work, pass `--model opus --effort max` unless there
  is a specific reason not to.
- Use `--model sonnet` only as an explicit lighter-cost escape hatch for routine,
  low-risk dispatches.
- Fable (`fable` / `claude-fable-5`) is known to this harness but is not a
  default or standing recommendation. Consider suggesting it to JPop only for
  token-efficient, important tasks such as architecture plans, high-stakes
  reviews, or compact strategic planning; get approval before dispatching it.
- Do not use Haiku/fast mode for Foreman unless the user explicitly asks for a
  fast/cheap pass.
- If multiple independent lanes help, run them concurrently and keep prompts
  sharply scoped.

## How To Dispatch

Use `scripts/dispatch.sh` for all invocations. It handles flag routing, JSON
parsing, cost logging, profile fallback, and artifact paths.

```bash
exec scripts/dispatch.sh <profile> <target_dir> "<prompt>" [flags]
```

- `<profile>` — one of: `plan`, `implement`, `review`, `wide-open`, `claws-out`
- `<target_dir>` — working directory (repo or workspace folder). Absolute paths
  preferred; relative paths resolve against the caller's current directory.
- `<prompt>` — the full task description for Claude CLI

Common examples:

```bash
exec scripts/dispatch.sh plan ~/.openclaw/workspace \
  "Review this template and suggest a better bootstrap block." \
  --model opus --effort max --max-turns 16

exec scripts/dispatch.sh review ~/projects/example \
  "Review the current branch vs main for regressions and missing tests." \
  --model opus --effort max --max-turns 20

exec scripts/dispatch.sh implement ~/projects/example \
  "Implement the agreed small refactor and run focused tests." \
  --model opus --effort max --max-turns 30
```

For repo work, add `--worktree` when isolation is useful:

```bash
exec scripts/dispatch.sh implement /path/to/repo "task..." --worktree
```

## Timeout Rule

Foreman runs often outlive short wrapper timeouts. Do not use tiny wrapper
timeouts like 120s. Prefer starting the process with an early yield, then poll.
Use bounded ceilings: about 900s for `plan`, 1800s for `implement`/`review`, and
3600s only for large codebase exploration plus edits/test loops.

If a run exits with `SIGKILL` and no Claude result, suspect wrapper timeout first.

## Prompting Rules

- Give Foreman the user intent, current decision state, files to read, and exact
  output shape.
- Tell Foreman which prior suggestions are confirmed vs. merely context.
- For parallel lanes, assign different angles so results are complementary.
- Ask for compact conclusions plus concrete artifacts, not open-ended essays.
- Keep external actions out of Foreman prompts unless explicitly authorized.

`dispatch.sh` appends a final-output guardrail for constrained profiles, so Claude
should end with a written summary rather than a final tool call.

## Post-Execution

After every dispatch:

1. Check stop reason.
2. Read and synthesize the `result`.
3. If `tool_use` ended without a summary, inspect saved artifacts and re-dispatch
   with an explicit final-summary requirement.
4. If `max_turns`, decide whether the partial result is enough or continue.
5. If permission denials occurred, adjust the profile or prompt only as needed.
6. For worktree runs, review the diff before merging.
7. Report back with the strongest recommendation, not an undigested transcript.

## Auth Profiles

Foreman defaults to ambient Claude CLI auth. On machines with multiple Claude
setup-token accounts, a run can pin a profile:

```bash
exec scripts/dispatch.sh plan /path/to/repo \
  "Reply exactly: FOREMAN_PROFILE_OK" \
  --model opus --effort max --profile work
```

Profile resolution is optional and env-only:

- Default profiles file: `~/.openclaw/claude-profiles.json`
- Override: `FOREMAN_CLAUDE_PROFILES_FILE=/path/to/claude-profiles.json`
- Shape: `profiles.<name>.env_var` names the env var containing the Claude setup
  token.
- Tokens never belong in scripts or profile JSON.

Do not conflate Foreman profile pinning with OpenClaw model-provider selection.
Foreman can pin a Claude account without adding a new `/models` provider.

## Mac Node Auth Router

For <YourMacNode>/Mac-hosted Claude work, keep tokens Mac-local and route auth through
`scripts/mac-node-claude-foreman-auth-router.sh`.

Canonical source:
- `skills/claude-foreman/scripts/mac-node-claude-foreman-auth-router.sh`

Installed Mac skill copy:
- `/Users/clawPop/.openclaw/skills/claude-foreman`

Convenience Mac command:
- `/Users/clawPop/.openclaw/bin/mac-node-claude-foreman-auth-router.sh`
- This should be a symlink to
  `/Users/clawPop/.openclaw/skills/claude-foreman/scripts/mac-node-claude-foreman-auth-router.sh`,
  not a second real copy.

Mac env file:
- `/Users/clawPop/.openclaw/.env`, mode `600`
- Default token variable: `ANTHROPIC_OAUTH_TOKEN`
- Optional profile variables: `ANTHROPIC_OAUTH_TOKEN1`, `ANTHROPIC_OAUTH_TOKEN2`

The router exports `CLAUDE_CODE_OAUTH_TOKEN` only for the child process, then
execs either `claude` directly or a command after `--`. This lets a Mac Foreman
dispatch inherit the setup token without putting token values in scripts,
profiles, logs, or repo files.

Examples:

```bash
/Users/clawPop/.openclaw/bin/mac-node-claude-foreman-auth-router.sh \
  -p "Reply exactly: MAC_ROUTER_OK"

/Users/clawPop/.openclaw/bin/mac-node-claude-foreman-auth-router.sh -- \
  /Users/clawPop/.openclaw/skills/claude-foreman/scripts/dispatch.sh plan /path/to/repo \
  "Review this and summarize findings."
```

## Budget Protection

**Hard limit: $80 per rolling 5-hour window.** The dispatch script sums costs
from the last 5 hours in `cost-log.json` before each run: if remaining budget
is under $5 the dispatch is **blocked** (override with `--force`); under $15 it
warns but proceeds. Respect the budget warnings, but do not let routine cost
concerns silently downgrade a user-requested Foreman run from Opus/max; report
the budget issue if it blocks or meaningfully changes the lane.

## Fallback

If Claude CLI is rate-limited or quota-blocked:

1. Try the configured profile fallback lane when available.
2. If still blocked, check whether Codex CLI is available and authed.
3. Otherwise log the failure and tell JPop what blocked the run.

## Logging

All dispatch metadata is logged to `cost-log.json` in this skill directory. Each
run also writes raw stream events under `artifacts/streams/`. Runtime learnings,
gotchas, and adjustments go in `NOTES.md`.
