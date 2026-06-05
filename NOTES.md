# Claude Foreman - Runtime Notes

Record learnings, gotchas, and adjustments here as the skill is used.

---

- 2026-04-26: Added `wide-open` as a root-safe, noninteractive alternative to `claws-out`. On Linux hosts running Claude as `root`, true bypass mode (`claws-out` / `bypassPermissions`) is blocked by Claude itself, but `dontAsk` plus a broad explicit allowlist still works for most repo tasks.
- 2026-06-01: Made Opus the documented and script-enforced default across all profiles. Sonnet remains an explicit lighter-cost escape hatch via `--model sonnet`.
- 2026-06-01: Expanded README/SKILL positioning so the public repo explains the real use case: orchestrator-owned delegation, context separation, second-opinion review, git-safe implementation packets, and Claude CLI dispatch discipline.
- 2026-06-01: Claude Foreman review of the public-copy diff confirmed Opus default was consistently enforced and recommended fixing profile-count wording, threshold consistency, unexplained ACPX jargon, and README section order before publishing.
- 2026-05-03: `stop_reason=tool_use` with an empty `result` means Claude ended while trying to use a tool and never wrote the requested summary. Treat as incomplete; re-dispatch with more turns and an explicit "stop inspecting and summarize before the last turn" instruction. `dispatch.sh` now saves raw artifacts under `artifacts/` for this case.
- 2026-05-03: `plan` profile is read-only but cannot fetch public URLs. Use `review` for read-only planning when the prompt includes docs links Claude should retrieve; it still runs with plan/read-only permission mode.
- 2026-05-01: OpenClaw wrapper timeouts can kill otherwise healthy Foreman runs with `SIGKILL`. Keep short yield/background behavior, but give `plan` about 900s and `implement`/`review` about 1800s unless the task is tiny. If a run dies with no Claude result, suspect wrapper timeout first.
- 2026-06-03: Fixed `--allowedTools` syntax: all Bash prefixes are now separate `Bash(cmd:*)` entries. The combined `Bash(a:*,b:*)` form is not accepted by Claude CLI. implement profile broadened to include `MultiEdit` and common shell/workflow utilities (bash, sh, source, rg, ls, cat, grep, find, test, env, wc, head, tail, sed, awk, cut, tr, sort, uniq, xargs, printf, echo, pwd, date, chmod, mkdir, cp, mv). plan and review similarly corrected and expanded with safe read-only shell utilities.
- 2026-06-03: Added final-output guardrail automatically appended to all constrained-profile prompts. This instructs Claude to stop tool use before the last turn and write a complete written summary. claws-out is exempt (no allowedTools constraint).
- 2026-06-03: Improved dispatch diagnostics: permission_denials are now parsed from Claude JSON, the count and first 5 denied tool/command inputs are printed to stderr. Artifacts are saved for any permission_denial, max_turns, error, or incomplete tool_use run (not just tool_use with empty result). permission_denial_count is recorded in every cost-log entry.
- 2026-06-04: Dispatch now uses Claude `stream-json --verbose`, saves the raw event stream to `artifacts/streams/`, and emits compact `[foreman:stream]` progress lines so the orchestrator can see liveness without raw JSON/context bloat.
