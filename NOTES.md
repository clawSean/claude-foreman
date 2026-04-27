# Claude Foreman - Runtime Notes

Record learnings, gotchas, and adjustments here as the skill is used.

---

- 2026-04-26: Added `wide-open` as a root-safe, noninteractive alternative to `claws-out`. On Linux hosts running Claude as `root`, true bypass mode (`claws-out` / `bypassPermissions`) is blocked by Claude itself, but `dontAsk` plus a broad explicit allowlist still works for most repo tasks.
