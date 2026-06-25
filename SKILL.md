---
name: claude-foreman
description: >
  Dispatch bounded planning, review, and implementation jobs to Claude CLI for
  isolated execution while the main agent remains orchestrator. Use when:
  editing large files (>50 lines changed), multi-file refactors, codebase
  exploration + implementation, restructuring workspace files, deep code
  reviews, or any task that would require more than 3-4 sequential tool calls.
  Do NOT use for quick one-line fixes, simple config changes, or short lookups.
---

# Claude Foreman

Delegate bounded work packets to Claude CLI while the main agent keeps ownership
of the conversation, memory, project state, and user intent. You orchestrate:
decide what to delegate, choose a permission profile, review the result, and
report back. Claude CLI executes the packet in isolation.

Claude Foreman is not a replacement model route. It is a repeatable dispatch
harness around Claude CLI and ACPX (OpenClaw's agent-to-agent CLI bridge):
permission profiles, cost logging, git-safe review flow, and final-summary
discipline.

Use it when separation is valuable:

- A second opinion or review pass should not pollute the main context.
- A large inspection/edit would distract or compact the orchestrator.
- Claude Opus is preferred for final edits, readability, or deeper judgment.
- The main agent should stay responsive while a heavier slice runs off-thread.
- You want a clean work packet with known permissions and auditable output.

## Profiles

Five execution profiles control what Claude CLI can do:

| Profile | Use For | Reference |
|---|---|---|
| `plan` | Analysis, architecture, planning — read-only | `profiles/plan.md` |
| `implement` | Code edits, file creation, refactors | `profiles/implement.md` |
| `review` | Code audit, PR review, quality checks | `profiles/review.md` |
| `wide-open` | Root-safe, noninteractive broad-access mode using explicit allowlists instead of bypass | `profiles/wide-open.md` |
| `claws-out` | 🦞 Full-access mode (bypass permissions; sandbox/trusted targets only, not usable under Linux root) | n/a |

`plan` is read-only but has no web-fetch tools. Use `review` for read-only planning
when the prompt includes public docs/URLs that Claude should fetch; `review` still
uses plan/read-only permission mode but adds URL retrieval tools.

**Default model: opus across all profiles.** Use `--model sonnet` only as an
explicit lighter-cost escape hatch for routine or low-risk dispatches.

## Dispatch Decision

**Use Claude Foreman when:**
- Estimated change is >50 lines or spans multiple files
- Task requires codebase exploration before acting
- Self-editing workspace files (restructuring memory, rewriting configs)
- Any operation you estimate would take >3-4 tool calls natively
- Deep code reviews or architecture analysis
- You want Claude's opinion without handing Claude the whole conversation
- You want implementation separated from orchestration so the main agent can
  keep project/user context intact

**Keep native when:**
- One-line fixes, small config tweaks
- Quick file reads or lookups
- Simple Q&A that doesn't need tool access

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

## How to Dispatch

Use `scripts/dispatch.sh` for all invocations. It handles flag routing,
JSON parsing, and cost tracking automatically.

**OpenClaw exec timeout rule:** Foreman runs often outlive short wrapper timeouts.
Do not use tiny `timeout` values like 120s for Foreman dispatches. Prefer
`yieldMs: 1000` so the process backgrounds quickly, then poll with
`process.poll`. For `exec.timeout`, use a generous but bounded ceiling by
default: `plan` 900s, `implement`/`review` 1800s. Use 3600s only when the prompt
explicitly involves large-codebase exploration plus edits, test/build loops,
dependency installs, or multi-repo/multi-phase work. Do not use 3600s for
ordinary doc edits or small patches. If the scope is unknown, first dispatch
`plan` with 900s to size the work, then run `implement` only after the plan is
clear. If a run exits with `SIGKILL` and no Claude result, suspect wrapper
timeout first.

```bash
exec scripts/dispatch.sh <profile> <target_dir> "<prompt>"
```

- `<profile>` — one of: `plan`, `implement`, `review`, `wide-open`, `claws-out` (`unsafe` still accepted as legacy alias; `root-wide` and `claws-wide` are accepted aliases for `wide-open`)
- `<target_dir>` — working directory (repo or workspace folder). Absolute paths are preferred; relative paths are resolved against the caller's current directory and echoed back in the dispatch log.
- `<prompt>` — the full task description for Claude CLI

### Examples

```bash
# Plan a refactor
exec scripts/dispatch.sh plan /Users/edgeclaw/Developer/myapp \
  "Analyze the auth middleware in src/middleware/auth.ts and plan how to migrate it from JWT to session-based auth. List all files that would need changes."

# Implement a feature
exec scripts/dispatch.sh implement /Users/edgeclaw/Developer/myapp \
  "Add rate limiting to all API routes in src/routes/. Use express-rate-limit. Limit to 100 requests per 15 minutes per IP. Add tests."

# Review code
exec scripts/dispatch.sh review /Users/edgeclaw/Developer/myapp \
  "Review the changes in the current branch vs main. Focus on security issues, error handling gaps, and performance concerns."

# Self-edit workspace files
exec scripts/dispatch.sh implement /Users/edgeclaw/.openclaw/workspace \
  "Reorganize the memory/notes/ directory. Consolidate duplicate entries, archive anything older than 30 days into memory/notes/archive/."

# Root-safe broad mode when you want something claws-out-ish without bypass
exec scripts/dispatch.sh wide-open /Users/edgeclaw/Developer/myapp \
  "Inspect the repo, run the needed shell commands, make the code changes, and summarize what changed."
```

### Optional Claude Account Profiles

Foreman defaults to ambient Claude CLI auth. Do not require Sean's local routing
wrapper for regular users.

On a machine with multiple Claude setup-token accounts, entering the
profile-aware `claude-cli` lane enables fallback by default:

```bash
exec scripts/dispatch.sh plan /path/to/repo \
  "Reply exactly: FOREMAN_PROFILE_OK" \
  --model sonnet \
  --provider claude-cli
```

Fallback order is active profile first, then the remaining profiles in
`claude-profiles.json`. Profiles with an active `cooldown_until` are
de-prioritized, not hard-skipped, so a single-profile setup still works.

A run can also pin a profile. Pinning is strict and never falls through to a
different account:

```bash
exec scripts/dispatch.sh plan /path/to/repo \
  "Reply exactly: FOREMAN_PROFILE_OK" \
  --model sonnet \
  --profile work
```

Profile resolution is optional and env-only:

- Default profiles file: `/root/.openclaw/claude-profiles.json`
- Override: `FOREMAN_CLAUDE_PROFILES_FILE=/path/to/claude-profiles.json`
- Shape: `profiles.<name>.env_var` names the env var containing the Claude
  setup token.
- Tokens never belong in scripts or the profiles JSON.
- `claude-auth-active` is the first-choice profile for `--provider claude-cli`.
- `--profile <name>` is strict for proof/debug runs.
- `--no-profile-fallback` keeps `--provider claude-cli` on the active/default
  profile without trying the rest of the list.
- Retry is limited to opening-request quota signals from Claude CLI failure
  surfaces, such as result events with `api_error_status: 429` or
  `assistant_error: rate_limit`. Foreman does not retry after tool use, token
  usage, or non-zero cost.
- Failed fallback profiles are cooled down in the profiles JSON for
  `FOREMAN_CLAUDE_PROFILE_COOLDOWN_SECONDS` seconds, default `300`.

Adding a profile/account:

1. Add a shell-safe token env var, e.g. `ANTHROPIC_OAUTH_TOKEN3`.
2. Add a `profiles.<name>` entry with `label`, `env_var`, and optional
   `cooldown_until`.
3. Run `scripts/smoke-claude-profile.sh --profile <name> --model sonnet`.
4. Only if the account should be selectable from OpenClaw `/models`, wire the
   OpenClaw CLI backend/model config separately and prove the agent pipeline with
   `scripts/smoke-openclaw-model.sh --model <provider/model>`.

Do not conflate Foreman profile pinning with OpenClaw model-provider selection:
Foreman can pin a Claude account without adding a new `/models` provider, and
normal Foreman use should keep working without any profile flags.

### Sean's Live Claude Router

Sean's local OpenClaw Claude CLI backend wrappers live outside the skill repo at
`/root/scripts/claude-auth-router.sh` and `/root/scripts/claude-work.sh`.

As of 2026-06-25:

- The live router does not retry the failed prompt.
- Interactive/no-`-p` sessions still pass straight through to Claude.
- Noninteractive `-p --output-format stream-json` calls convert known opening
  rate-limit/session-limit failures into a friendly, emoji-bearing synthetic
  success result so the caller can ask the user to try again instead of
  surfacing raw quota text.
- For implicit active-profile calls, a known rate/session-limit hit cools down
  the current profile, switches `claude-auth-active` to the next usable profile,
  and asks the caller to send the last message again now. Explicit
  `--auth-profile`/`--profile` calls remain pinned.
- The classifier is grounded in real Claude CLI artifacts:
  `rate_limit_event.status=rejected`, `assistant.error=rate_limit`, result
  `is_error=true` with `api_error_status` `429`/`529`, and the exact
  `You've hit your session limit` text.
- Run `scripts/test-claude-auth-router.sh` to regression-test the live wrapper
  with a fake `claude` binary. No live Claude/API call is made.

### Claws-Out Profile (Full Access)

Use `claws-out` when you explicitly want full-access execution (`bypassPermissions`) in a trusted/sandboxed environment and accept the extra risk. It is for "do whatever it takes" runs, not normal use.

On Linux hosts where the CLI is running as `root`, `claws-out` is blocked by Claude itself. In those environments, use `wide-open` as the nearest root-safe approximation.

Recommended rule:
- default to `plan`, `review`, or `implement`
- use `wide-open` when you need noninteractive broad access on a root-run host
- use `claws-out` only when the target is a throwaway sandbox, isolated non-root environment, or similarly contained environment
- do not use `claws-out` for casual reviews, routine edits, or shared production environments
- legacy alias `unsafe` is still accepted for compatibility

### Worktree Isolation

For repo work, add `--worktree` as an extra arg to run in an isolated git worktree:

```bash
exec scripts/dispatch.sh implement /path/to/repo "task..." --worktree
```

The script will include the worktree flag. After completion, review the diff
in the worktree branch and merge if clean.

## Budget Protection

**Hard limit: $80 per rolling 5-hour window** (matches Pro plan reset cycle).

The dispatch script tracks every invocation's cost in `cost-log.json` (local
to this skill directory). Before each dispatch:

1. Script sums costs from the last 5 hours
2. If remaining budget < $5, dispatch is **blocked** with a warning
3. If remaining budget < $15, a warning is printed but dispatch proceeds

If blocked, wait for the window to roll or explicitly override with `--force`.

Opus is the default because Foreman is mainly for work where stronger judgment,
review quality, or readability matters. Use `--model sonnet` intentionally for
lighter tasks when cost/speed matters more than depth.

## Post-Execution

After every dispatch, check the result:

1. **`stop_reason: end_turn`** — task completed normally. Review output.
2. **`stop_reason: tool_use` with empty result** — Claude stopped while trying
   to use a tool before writing the requested summary. Treat this as incomplete:
   inspect any saved artifact paths printed by `dispatch.sh`, then re-dispatch
   with more turns and an explicit instruction such as: "End with a written
   summary even if you must stop inspecting files."
3. **`stop_reason: max_turns`** — task hit the turn limit. May be incomplete.
   Decide whether to continue (re-dispatch with context) or accept partial work.
4. **Permission denials** — if Claude tried a command outside the allowlist,
   `dispatch.sh` prints the denial count and the first five denied tool/command
   inputs. Check whether the profile needs broadening or the prompt needs
   scoping. Artifacts are saved to `artifacts/` automatically.
5. **Parse `result`** — this is Claude CLI's final text output. Use it to
   summarize what was done back to the user or to your own logs.
6. **For worktree runs** — check the diff in the worktree branch before merging.

`dispatch.sh` saves raw stdout/stderr artifacts under `artifacts/` for any run
that ends with `max_turns`, `error`, an incomplete `tool_use`, or any permission
denials. The artifact filename encodes the timestamp, profile, and reason.
`cost-log.json` entries include `permission_denial_count` for auditing.
Each run also writes the raw Claude `stream-json` event log to
`artifacts/streams/` and prints the path in the dispatch banner. Use that file's
mtime or tail for liveness/audit checks; Foreman emits only compact filtered
progress lines to the parent process.

## Prompt Crafting Tips

`dispatch.sh` automatically appends a final-output guardrail to every constrained
profile prompt (plan, implement, review, wide-open). The guardrail instructs
Claude to stop tool use before the last turn and write a complete written summary.
You do not need to add this manually. `claws-out` is exempt.

When the user gives public documentation URLs, prefer `review` over `plan` so
Claude can fetch those URLs. When local docs are enough, `plan` is cheaper and
more constrained.

## Codex Fallback (Optional)

If Claude CLI is rate-limited or quota-blocked:

1. Check if `codex` binary exists and is authed: `which codex && codex auth status`
2. If available, re-dispatch the task to Codex with equivalent constraints
3. If not available, log the failure and retry after a cooldown period

This is optional — skip if Codex is not yet configured.

## Logging

All dispatch metadata is logged to `cost-log.json` in this skill directory.
Each entry records: timestamp, profile, model, turns used, cost, stop reason,
and a short task summary. Use this for auditing and budget tracking.

Runtime learnings, gotchas, and adjustments go in `NOTES.md`.

## Enforcement Setup

The skill file alone is passive — OpenClaw loads it contextually based on
description matching, which means the agent can skip it during mid-conversation
decisions. To make dispatch mandatory, inject the rule into layers the agent
cannot ignore. Listed by importance:

### 1. SOUL.md (highest priority — always loaded at bootstrap)

Add a section to your workspace `SOUL.md`:

```markdown
## Heavy Lifting — Non-Negotiable

For any task involving >50 lines of changes, multiple file edits, deep
codebase exploration, or >3-4 sequential tool calls: **dispatch to Claude CLI**
via the `claude-foreman` skill. No exceptions. I orchestrate, Claude CLI
executes. Read `skills/claude-foreman/SKILL.md` for profiles and usage.
This applies to coding tasks, workspace self-edits, and anything that would
burn through my context doing natively.
```

**Why this works:** SOUL.md is read every session before anything else. It
defines who the agent _is_, not just what it should do. Rules here carry
the weight of identity.

### 2. Per-channel systemPrompt (config-level — always injected, never compacted)

Add to each channel in `openclaw.json`. This is injected into the system
prompt by the gateway, so it survives context compaction.

**Telegram** — set on the wildcard group entry so it applies to all groups:

```json
{
  "channels": {
    "telegram": {
      "groups": {
        "*": {
          "systemPrompt": "STANDING RULE — Claude Foreman: For any task involving >50 lines of changes, multiple file edits, deep codebase exploration, or >3-4 sequential tool calls, you MUST dispatch to Claude CLI via the claude-foreman skill (skills/claude-foreman/SKILL.md) instead of doing the work natively. You orchestrate, Claude CLI executes. No exceptions."
        }
      }
    }
  }
}
```

**Slack** — does **not** support `systemPrompt` at the channel level as of
OpenClaw 2026.3.x. Slack sessions rely on SOUL.md and AGENTS.md for
behavioral rules. This makes layer 1 (SOUL.md) even more critical if you
use Slack.

**Note:** `channels.defaults.systemPrompt` and `agents.defaults.systemPrompt`
are also **not valid keys**. There is no global system prompt config — only
Telegram groups support it today. See
[GitHub issue #36190](https://github.com/openclaw/openclaw/issues/36190)
for the proposed `systemPromptFile` feature that would cover all channels.

### 3. AGENTS.md Tools section (reinforcement — loaded at bootstrap, may compact)

Add a "Claude Foreman" subsection under `## Tools` in your workspace
`AGENTS.md`. Include dispatch thresholds, usage syntax, budget rules, and
the key rule: "you orchestrate, Claude CLI executes."

This provides the operational detail that SOUL.md and systemPrompt keep
intentionally brief.

### 4. lessons.md (behavioral rule — loaded contextually)

Add a "Do X, not Y" entry to `memory/lessons/lessons.md`:

```markdown
## Use Claude Foreman for Heavy Lifts

### Don't try to do large edits natively — dispatch to Claude CLI
**Do:** Use the claude-foreman skill for any task >50 lines, multiple files, or >3-4 sequential tool calls.
**Don't:** Attempt large refactors or multi-file edits through native tool calls.
```

### 5. MEMORY.md Hot Items (quick-scan reminder — loaded in main sessions)

Add a one-liner to the Hot Items section:

```markdown
- **Claude Foreman skill (2026-04-04):** ✅ Installed. USE IT for anything
  >50 lines, multiple files, or >3-4 sequential tool calls. See AGENTS.md and skills/claude-foreman/.
```

### Summary

| Layer | Scope | Survives compaction? | Priority |
|---|---|---|---|
| SOUL.md | Every session | Yes (bootstrap file) | Highest |
| Per-channel systemPrompt | Telegram only | Yes (gateway config) | High |
| AGENTS.md | Every session | Sometimes (can compact) | Medium |
| lessons.md | Contextual | Sometimes (contextual load) | Medium |
| MEMORY.md | Main sessions only | Sometimes (can compact) | Lowest |

Layers 1-2 are bulletproof. Layers 3-5 are reinforcement. At minimum,
set up layers 1 and 2.
