# Claude Foreman - Runtime Notes

Record learnings, gotchas, and adjustments here as the skill is used.

---

- 2026-04-26: Added `wide-open` as a root-safe, noninteractive alternative to `claws-out`. On Linux hosts running Claude as `root`, true bypass mode (`claws-out` / `bypassPermissions`) is blocked by Claude itself, but `dontAsk` plus a broad explicit allowlist still works for most repo tasks.
- 2026-06-01: Made Opus the documented and script-enforced default across all profiles. Sonnet remains an explicit lighter-cost escape hatch via `--model sonnet`.
- 2026-06-01: Expanded README/SKILL positioning so the public repo explains the real use case: orchestrator-owned delegation, context separation, second-opinion review, git-safe implementation packets, and Claude CLI dispatch discipline.
- 2026-06-01: Claude Foreman review of the public-copy diff confirmed Opus default was consistently enforced and recommended fixing profile-count wording, threshold consistency, unexplained ACPX jargon, and README section order before publishing.
- 2026-05-03: `stop_reason=tool_use` with an empty `result` means Claude ended while trying to use a tool and never wrote the requested summary. Treat as incomplete; re-dispatch with more turns and an explicit "stop inspecting and summarize before the last turn" instruction. `dispatch.sh` now saves raw artifacts under `artifacts/` for this case.
- 2026-05-03: `plan` profile is read-only but cannot fetch public URLs. Use `review` for read-only planning when the prompt includes docs links Claude should retrieve; it still runs with plan/read-only permission mode.
