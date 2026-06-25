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
scripts/dispatch.sh <profile> <target_dir> "<prompt>" [--model <alias>] [--worktree] [--force] [--max-turns N] [--provider claude-cli|claude-work] [--profile <name>] [--no-profile-fallback]
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

On machines with multiple Claude setup-token accounts, Foreman can use the
profile-aware `claude-cli` lane. With `--provider claude-cli`, fallback is the
default behavior: Foreman tries the active profile first, then the remaining
profiles in `claude-profiles.json`, de-prioritizing profiles whose
`cooldown_until` is still active. If only one profile exists, it simply runs that
profile once.

```bash
scripts/dispatch.sh plan /path/to/repo \
  "Reply exactly: FOREMAN_PROFILE_OK" \
  --model sonnet \
  --provider claude-cli
```

Explicit profile pinning stays strict and never falls through to another
account:

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
- `claude-auth-active` is the first-choice profile for the `claude-cli` fallback
  lane. If it is absent, the JSON `active` field is used.
- `--profile <name>` is strict by design. Use it for proof runs and debugging.
- `--no-profile-fallback` keeps `--provider claude-cli` on the active/default
  profile without trying the rest of the profile list.
- `claude-work` is treated as the `work` profile for Sean's local OpenClaw
  setup; regular Foreman users do not need that provider wrapper.
- Fallback only retries opening-request quota failures, such as a Claude CLI
  result event with `api_error_status: 429` or `assistant_error: rate_limit`.
  Foreman does not retry after tool use, token usage, or non-zero cost, so it
  does not duplicate a run that already made progress.
- Failed fallback profiles are cooled down in the profiles JSON for
  `FOREMAN_CLAUDE_PROFILE_COOLDOWN_SECONDS` seconds, default `300`.

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
uses profile auth when the caller enters the profile-aware lane with
`--provider` or pins an account with `--profile`.

## Live Smoke Tests

The reusable smoke tests save artifacts under `artifacts/smokes/`.

```bash
# Direct Claude CLI account/profile proof. Prints parsed response text.
scripts/smoke-claude-profile.sh --profile work --model sonnet

# OpenClaw selectable provider proof through the agent pipeline. Prints parsed response text.
scripts/smoke-openclaw-model.sh --model claude-work/claude-sonnet-4-6
```

## Sean's Live Claude Auth Router

Sean's local OpenClaw Claude CLI backends use
`/root/scripts/claude-auth-router.sh` and `/root/scripts/claude-work.sh`.
Those scripts are intentionally outside this standalone skill repo, but this
repo carries an offline regression test for the live router:

```bash
scripts/test-claude-auth-router.sh
```

Current router behavior:

- Interactive/no-`-p` Claude sessions still `exec claude "$@"` and pass through.
- Noninteractive `-p` calls with `--output-format stream-json` are streamed
  through a tiny classifier.
- Known opening rate-limit/session-limit failures are converted into a friendly
  synthetic success result instead of raw Claude CLI quota text.
- The router does not retry another account/profile yet. Account rotation lives
  in Foreman's bounded `--provider claude-cli` dispatch lane.
- The classifier keys on failure-channel surfaces observed in real logs:
  `rate_limit_event.status=rejected`, `assistant.error=rate_limit`, result
  `is_error=true` plus `api_error_status` `429`/`529`, or the exact
  `You've hit your session limit` wording.
- Successful content that merely talks about "rate limit" is passed through and
  does not trigger the friendly rewrite.

## Notes
This skill is intended for heavier or higher-stakes work where native tool-call editing would be inefficient, context-expensive, or better handled by a separated reviewer/implementer.
