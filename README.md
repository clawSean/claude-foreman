# claude-foreman

**Canonical source:** this standalone repo, `clawSean/claude-foreman`.

The SkillReef collection may carry a mirrored distribution copy at
`clawSean/skillreef/skills/claude-foreman`, but changes should originate here
first and then be synced outward.

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
- `scripts/dispatch.sh` with budget guardrails, structured logging, permission-denial diagnostics, and auto-appended final-output guardrail
- `NOTES.md` for runtime learnings

## Quickstart

```bash
scripts/dispatch.sh review /path/to/repo \
  "Review the current diff. Focus on correctness, risk, and missing tests."
```

Expected result: Foreman prints the selected profile/model, the raw stream path,
compact live progress lines, cost/turn metadata, and Claude's final summary. For
write-profile runs, review the git diff before merging or copying changes
forward.

Raw Claude `stream-json` events are saved under `artifacts/streams/` for
auditing and liveness checks. Foreman only prints compact filtered progress to
the parent process; it does not dump raw JSON into chat/context.

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

## Optional Claude Account Profiles

Foreman normally inherits the caller's ambient Claude CLI auth. That keeps the
standalone skill portable: users who only have one `claude` login can keep using
the normal dispatch command with no profile setup.

On machines with multiple Claude setup-token accounts, Foreman can pin an auth
profile for a run:

```bash
scripts/dispatch.sh plan /path/to/repo \
  "Reply exactly: FOREMAN_PROFILE_OK" \
  --model sonnet \
  --profile work
```

When `--profile <name>` or `--provider claude-cli|claude-work` is supplied,
Foreman resolves auth through a profiles JSON file:

```json
{
  "active": "personal",
  "profiles": {
    "personal": {
      "label": "JPop Personal",
      "env_var": "ANTHROPIC_OAUTH_TOKEN1"
    },
    "work": {
      "label": "Edge Company",
      "env_var": "ANTHROPIC_OAUTH_TOKEN2"
    }
  }
}
```

Default path: `/root/.openclaw/claude-profiles.json`

Override path for portable installs:

```bash
FOREMAN_CLAUDE_PROFILES_FILE=/path/to/claude-profiles.json \
  scripts/dispatch.sh plan /path/to/repo "..." --profile work
```

Rules:
- Tokens live only in the environment. The profiles file stores env var names,
  not token values.
- Env var names must be shell-safe: `[A-Za-z_][A-Za-z0-9_]*`.
- `claude-auth-active` is only a local default-profile switch for the
  `claude-cli` lane. It is not automatic failover.
- `claude-work` is treated as the `work` profile for Sean's local OpenClaw
  setup; regular Foreman users do not need that provider wrapper.

To add another account/profile:

1. Export a new Claude setup token in the runtime env, for example
   `ANTHROPIC_OAUTH_TOKEN3`.
2. Add a profile entry:

```json
"backup": {
  "label": "Backup Claude Seat",
  "env_var": "ANTHROPIC_OAUTH_TOKEN3",
  "cooldown_until": 0
}
```

3. Smoke test the profile:

```bash
scripts/smoke-claude-profile.sh --profile backup --model sonnet
```

4. If the account should appear as an OpenClaw `/models` selectable provider,
   add or update the OpenClaw CLI backend/model config separately and validate it
   with:

```bash
scripts/smoke-openclaw-model.sh --model claude-work/claude-sonnet-4-6
```

That OpenClaw provider step is intentionally separate from Foreman. Foreman only
needs profile auth when the caller explicitly asks it to pin an account.

## Live Smoke Tests

The reusable smoke tests save artifacts under `artifacts/smokes/`.

```bash
# Direct Claude CLI account/profile proof. Prints parsed response text.
scripts/smoke-claude-profile.sh --profile work --model sonnet

# OpenClaw selectable provider proof through the agent pipeline. Prints parsed response text.
scripts/smoke-openclaw-model.sh --model claude-work/claude-sonnet-4-6
```

## Notes
This skill is intended for heavier or higher-stakes work where native tool-call editing would be inefficient, context-expensive, or better handled by a separated reviewer/implementer.
