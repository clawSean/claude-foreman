---
name: claude-foreman
description: >
  Dispatch heavy-lift tasks to Claude CLI for isolated execution. Use when:
  editing large files (>50 lines changed), multi-file refactors, codebase
  exploration + implementation, restructuring workspace files, deep code
  reviews, or any task that would require more than 3-4 sequential tool calls.
  Do NOT use for quick one-line fixes, simple config changes, or short lookups.
---

# Claude Foreman

Delegate heavy work to Claude CLI. You orchestrate (decide what, when, why).
Claude CLI executes (does the work in isolation).

## Profiles

Four execution profiles control what Claude CLI can do:

| Profile | Use For | Reference |
|---|---|---|
| `plan` | Analysis, architecture, planning — read-only | `profiles/plan.md` |
| `implement` | Code edits, file creation, refactors | `profiles/implement.md` |
| `review` | Code audit, PR review, quality checks | `profiles/review.md` |
| `wide-open` | Root-safe, noninteractive broad-access mode using explicit allowlists instead of bypass | `profiles/wide-open.md` |
| `claws-out` | 🦞 Full-access mode (bypass permissions; sandbox/trusted targets only, not usable under Linux root) | n/a |

Default model is **sonnet**. Opus is currently disabled to conserve budget.

## Dispatch Decision

**Use Claude CLI when:**
- Estimated change is >50 lines or spans multiple files
- Task requires codebase exploration before acting
- Self-editing workspace files (restructuring memory, rewriting configs)
- Any operation you estimate would take >3-4 tool calls natively
- Deep code reviews or architecture analysis

**Keep native when:**
- One-line fixes, small config tweaks
- Quick file reads or lookups
- Simple Q&A that doesn't need tool access

## How to Dispatch

Use `scripts/dispatch.sh` for all invocations. It handles flag routing,
JSON parsing, and cost tracking automatically.

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

Opus is currently disabled. Sonnet only.

## Post-Execution

After every dispatch, check the result:

1. **`stop_reason: end_turn`** — task completed normally. Review output.
2. **`stop_reason: max_turns`** — task hit the turn limit. May be incomplete.
   Decide whether to continue (re-dispatch with context) or accept partial work.
3. **Parse `result`** — this is Claude CLI's final text output. Use it to
   summarize what was done back to the user or to your own logs.
4. **For worktree runs** — check the diff in the worktree branch before merging.

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

For any task involving >20 lines of changes, multiple file edits, deep
codebase exploration, or >2 sequential tool calls: **dispatch to Claude CLI**
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
          "systemPrompt": "STANDING RULE — Claude Foreman: For any task involving >20 lines of changes, multiple file edits, deep codebase exploration, or >2 sequential tool calls, you MUST dispatch to Claude CLI via the claude-foreman skill (skills/claude-foreman/SKILL.md) instead of doing the work natively. You orchestrate, Claude CLI executes. No exceptions."
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
**Do:** Use the claude-foreman skill for any task >20 lines or >2 tool calls.
**Don't:** Attempt large refactors or multi-file edits through native tool calls.
```

### 5. MEMORY.md Hot Items (quick-scan reminder — loaded in main sessions)

Add a one-liner to the Hot Items section:

```markdown
- **Claude Foreman skill (2026-04-04):** ✅ Installed. USE IT for anything
  >20 lines or >2 tool calls. See AGENTS.md and skills/claude-foreman/.
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
