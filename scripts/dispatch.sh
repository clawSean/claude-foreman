#!/usr/bin/env bash
# claude-foreman dispatch script
# Usage: dispatch.sh <profile> <target_dir> "<prompt>" [extra_flags...]
#
# Profiles: plan, implement, review, wide-open, claws-out (legacy alias: unsafe)
# Extra flags: --model opus, --worktree, --force, --max-turns N

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COST_LOG="$SKILL_DIR/cost-log.json"
BUDGET_LIMIT=80        # dollars per rolling window
BUDGET_WINDOW=18000    # 5 hours in seconds
BUDGET_WARN=15         # warn when remaining < this
BUDGET_BLOCK=5         # block when remaining < this

# --- Args ---
PROFILE="${1:?Usage: dispatch.sh <profile> <target_dir> \"<prompt>\" [flags...]}"
TARGET_DIR="${2:?Missing target directory}"
ORIGINAL_TARGET_DIR="$TARGET_DIR"
PROMPT="${3:?Missing prompt}"
shift 3

# --- Parse extra flags ---
MODEL=""
WORKTREE=""
FORCE=""
EXTRA_MAX_TURNS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --worktree)
      WORKTREE="1"
      shift
      ;;
    --force)
      FORCE="1"
      shift
      ;;
    --max-turns)
      EXTRA_MAX_TURNS="$2"
      shift 2
      ;;
    *)
      echo "[foreman] Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

# --- Normalize target directory early ---
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "[foreman] Target directory does not exist: $TARGET_DIR" >&2
  exit 1
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"

# --- Profile flags ---
case "$PROFILE" in
  plan)
    PERM_MODE="plan"
    ALLOWED_TOOLS="Read,Glob,Grep,Bash(git:*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-15}"
    DEFAULT_MODEL="sonnet"
    ;;
  implement)
    PERM_MODE="acceptEdits"
    ALLOWED_TOOLS="Read,Glob,Grep,Edit,Write,Bash(git:*,npm:*,npx:*,node:*,python:*,python3:*,pip:*,cargo:*,go:*,make:*,yarn:*,pnpm:*,bun:*,deno:*,pytest:*,jest:*,tsc:*,eslint:*,prettier:*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-30}"
    DEFAULT_MODEL="sonnet"
    ;;
  review)
    PERM_MODE="plan"
    ALLOWED_TOOLS="Read,Glob,Grep,WebFetch,Bash(git:*),Bash(curl:*),Bash(wget:*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-15}"
    DEFAULT_MODEL="sonnet"
    ;;
  wide-open|root-wide|claws-wide)
    PERM_MODE="dontAsk"
    ALLOWED_TOOLS="Read,Glob,Grep,Edit,MultiEdit,Write,WebFetch,Bash(*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-25}"
    DEFAULT_MODEL="sonnet"
    ;;
  claws-out|unsafe)
    # keep `unsafe` as a compatibility alias
    if [[ "$PROFILE" == "unsafe" ]]; then
      echo "[foreman] NOTE: profile 'unsafe' is deprecated; use 'claws-out'" >&2
    fi
    PERM_MODE="bypassPermissions"
    ALLOWED_TOOLS=""
    MAX_TURNS="${EXTRA_MAX_TURNS:-20}"
    DEFAULT_MODEL="sonnet"
    ;;
  *)
    echo "[foreman] Unknown profile: $PROFILE (use: plan, implement, review, wide-open, claws-out)" >&2
    exit 1
    ;;
esac

if [[ "$PROFILE" =~ ^(claws-out|unsafe)$ ]] && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "[foreman] Profile '$PROFILE' is not usable when running as Linux root." >&2
  echo "[foreman] Claude blocks bypass-style permission modes under root/sudo." >&2
  echo "[foreman] Use 'wide-open' for the closest root-safe noninteractive mode, or 'implement' for normal coding work." >&2
  exit 3
fi

MODEL="${MODEL:-$DEFAULT_MODEL}"

# --- Initialize cost log if missing ---
if [[ ! -f "$COST_LOG" ]]; then
  echo '[]' > "$COST_LOG"
fi

# --- Budget check ---
NOW=$(date +%s)
CUTOFF=$((NOW - BUDGET_WINDOW))

SPENT=$(python3 -c "
import json, sys
try:
    entries = json.load(open('$COST_LOG'))
except:
    entries = []
total = sum(e.get('cost_usd', 0) for e in entries if e.get('timestamp', 0) >= $CUTOFF)
print(f'{total:.4f}')
")

REMAINING=$(python3 -c "print(f'{$BUDGET_LIMIT - $SPENT:.4f}')")

if [[ "$FORCE" != "1" ]]; then
  BLOCKED=$(python3 -c "print('1' if $REMAINING < $BUDGET_BLOCK else '0')")
  if [[ "$BLOCKED" == "1" ]]; then
    echo "[foreman] BLOCKED: Only \$$REMAINING remaining in 5h window (\$$SPENT / \$$BUDGET_LIMIT spent)." >&2
    echo "[foreman] Wait for the window to roll or use --force to override." >&2
    exit 2
  fi

  WARNED=$(python3 -c "print('1' if $REMAINING < $BUDGET_WARN else '0')")
  if [[ "$WARNED" == "1" ]]; then
    echo "[foreman] WARNING: \$$REMAINING remaining in 5h window. Proceeding cautiously." >&2
  fi
fi

echo "[foreman] Dispatching: profile=$PROFILE model=$MODEL turns=$MAX_TURNS budget_remaining=\$$REMAINING"
if [[ "$ORIGINAL_TARGET_DIR" != "$TARGET_DIR" ]]; then
  echo "[foreman] Target: $ORIGINAL_TARGET_DIR -> $TARGET_DIR"
else
  echo "[foreman] Target: $TARGET_DIR"
fi
echo "[foreman] Prompt: ${PROMPT:0:120}..."

# --- Build command ---
CMD=(
  claude
  -p "$PROMPT"
  --model "$MODEL"
  --permission-mode "$PERM_MODE"
  --allowedTools "$ALLOWED_TOOLS"
  --max-turns "$MAX_TURNS"
  --output-format json
  --no-session-persistence
)

if [[ -n "$WORKTREE" ]]; then
  CMD+=(--worktree)
fi

# --- Execute ---
TMPOUT=$(mktemp)
TMPERR=$(mktemp)
trap "rm -f '$TMPOUT' '$TMPERR'" EXIT

cd "$TARGET_DIR"

if "${CMD[@]}" > "$TMPOUT" 2> "$TMPERR"; then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

# --- Parse output ---
if [[ -s "$TMPOUT" ]]; then
  RESULT_TEXT=$(python3 -c "
import json, sys
try:
    d = json.load(open('$TMPOUT'))
    print(d.get('result', ''))
except:
    print(open('$TMPOUT').read())
" 2>/dev/null || cat "$TMPOUT")

  COST=$(python3 -c "
import json
try:
    d = json.load(open('$TMPOUT'))
    print(d.get('total_cost_usd', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

  NUM_TURNS=$(python3 -c "
import json
try:
    d = json.load(open('$TMPOUT'))
    print(d.get('num_turns', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

  STOP_REASON=$(python3 -c "
import json
try:
    d = json.load(open('$TMPOUT'))
    print(d.get('stop_reason', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

  SESSION_ID=$(python3 -c "
import json
try:
    d = json.load(open('$TMPOUT'))
    print(d.get('session_id', ''))
except:
    print('')
" 2>/dev/null || echo "")
else
  RESULT_TEXT="(no output)"
  COST=0
  NUM_TURNS=0
  STOP_REASON="error"
  SESSION_ID=""
fi

# --- Log cost ---
TASK_SUMMARY="${PROMPT:0:80}"
python3 -c "
import json, time
log_path = '$COST_LOG'
try:
    entries = json.load(open(log_path))
except:
    entries = []
entries.append({
    'timestamp': int(time.time()),
    'iso': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
    'profile': '$PROFILE',
    'model': '$MODEL',
    'turns_used': $NUM_TURNS,
    'max_turns': $MAX_TURNS,
    'cost_usd': $COST,
    'stop_reason': '$STOP_REASON',
    'session_id': '$SESSION_ID',
    'target': '$TARGET_DIR',
    'task': '''$TASK_SUMMARY'''
})
# Keep last 200 entries to prevent unbounded growth
entries = entries[-200:]
json.dump(entries, open(log_path, 'w'), indent=2)
"

# --- Report ---
NEW_SPENT=$(python3 -c "print(f'{$SPENT + $COST:.4f}')")

echo ""
echo "[foreman] === Dispatch Complete ==="
echo "[foreman] Stop reason: $STOP_REASON"
echo "[foreman] Turns used: $NUM_TURNS / $MAX_TURNS"
echo "[foreman] Cost: \$$COST"
echo "[foreman] 5h window spend: \$$NEW_SPENT / \$$BUDGET_LIMIT"
if [[ -n "$SESSION_ID" ]]; then
  echo "[foreman] Session: $SESSION_ID"
fi

if [[ "$STOP_REASON" == "max_turns" ]]; then
  echo "[foreman] WARNING: Hit turn limit — task may be incomplete." >&2
fi

if [[ -s "$TMPERR" ]]; then
  echo "[foreman] Stderr:" >&2
  cat "$TMPERR" >&2
fi

# --- Output result ---
echo ""
echo "$RESULT_TEXT"

exit $EXIT_CODE
