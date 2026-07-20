# Claude Foreman — Phase 2 & Future Ideas

Ideas deferred from the Phase 1 acpx rewrite. Pick these up when ready.

---

## Phase 2 (prioritized)

### Budget Tracking
Re-introduce per-dispatch cost logging now that acpx is the harness.

- Log to `cost-log.json`: timestamp, profile, model, turns, cost, stop_reason, target, task summary
- Rolling 5h window spend check before dispatch
- Warn at $15 remaining, block at $5 remaining (override with `--force`)
- `acpx --format json` output should include `total_cost_usd` — verify field name against real output first
- Keep last 200 log entries to prevent unbounded growth

### Worktree Isolation
For repo work, run in an isolated git worktree so changes don't land on main until reviewed.

- Add `--worktree` flag to dispatch.sh
- Pass through to `acpx --worktree` if supported, or set up git worktree manually before dispatch
- After completion, diff the worktree branch; merge if clean
- Log worktree dispatches with a `[worktree]` tag in output
- Not needed for workspace self-edits (workspace isn't a typical git repo)

---

## Future Ideas

### Retry on Transient Errors
`acpx` has `--prompt-retries <count>`. Wire it in: default 1 retry for
`error` stop_reason, configurable via `--retries N` flag. Currently if
acpx hits a transient error, the dispatch just fails hard.

### Named Session Support
`acpx claude prompt` (vs `exec`) uses a persistent session. Could be useful
for iterative work where you want Claude to remember context across dispatches
(e.g., a multi-step refactor over several calls). Would need a session name
convention and cleanup logic.

### Prompt Templates per Profile
Standardized prompt prefixes/suffixes per profile. E.g., `implement` always
appends "End with a one-paragraph summary of changes made." Could live in
`profiles/<name>.prompt-suffix.txt` and be injected by dispatch.sh.

### TaskFlow Integration
When a dispatch is part of a larger TaskFlow job, log the acpx run as a
linked child task. Enables inspection of which Foreman dispatches belong to
which durable job. See `skills/taskflow/SKILL.md`.

### Ralph Wiggum Loop Integration
Ralph already has `[foreman]` dispatch tagging in RALPH_LOG.md. Could go
further: Ralph auto-selects profile based on slice size (reads-only = plan,
writes = implement), surfaces stop_reason in the iteration log, and handles
max_turns by automatically re-dispatching with remaining context.

### Model Auto-Selection
Instead of always defaulting to opus, estimate task complexity from the prompt
and target dir size, and auto-select sonnet for lightweight work. Override
still available with `--model`. Saves cost on easy dispatches.

### Streaming Output
For long-running dispatches, tail the temp output file and forward partial
output back to the calling session so there's visible progress. Useful for
wide-open runs that might take several minutes.

### tmux Supervision
Use bundled `tmux` for Foreman runs that need interactive/persistent terminal
supervision: launch or attach in a named session, capture panes for liveness,
and send keys only after a prompt is understood. This complements ACPX/Foreman;
it does not replace ACPX or conflict with it. Good candidates are stuck prompts,
manual approvals, long-running CLI smoke sessions, and Mac-node terminal work.

### acpx flow Support
`acpx flow` runs multi-step workflow files. Could replace complex dispatch.sh
logic for multi-phase work (plan → review output → implement → verify).
Investigate `acpx flow --help` when available.

---

*Created: 2026-05-08 — Phase 1 acpx rewrite*
