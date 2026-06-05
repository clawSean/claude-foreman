#!/usr/bin/env bash
# claude-foreman dispatch script
# Usage: dispatch.sh <profile> <target_dir> "<prompt>" [extra_flags...]
#
# Profiles: plan, implement, review, wide-open, claws-out (legacy alias: unsafe)
# Extra flags: --model sonnet, --worktree, --force, --max-turns N

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COST_LOG="$SKILL_DIR/cost-log.json"
ARTIFACT_DIR="$SKILL_DIR/artifacts"
STREAM_DIR="$ARTIFACT_DIR/streams"
STREAM_KEEP=50         # number of per-run stream files to retain
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

# Appended to prompts for all constrained profiles to prevent runs that end on
# a tool call with no written summary.
GUARDRAIL="

---
FINAL-OUTPUT REQUIREMENT: Before using your last available turn, stop any
ongoing file inspection or tool use and write a complete written summary:
what was done, what was found, decisions made, blockers encountered, and
recommended next steps. Your final response MUST be written prose, not a
tool call."

ADD_GUARDRAIL=1

# --- Profile flags ---
case "$PROFILE" in
  plan)
    PERM_MODE="plan"
    ALLOWED_TOOLS="Read,Glob,Grep,Bash(git:*),Bash(ls:*),Bash(cat:*),Bash(wc:*),Bash(head:*),Bash(tail:*),Bash(env:*),Bash(pwd:*),Bash(date:*),Bash(find:*),Bash(echo:*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-15}"
    DEFAULT_MODEL="opus"
    ;;
  implement)
    PERM_MODE="acceptEdits"
    ALLOWED_TOOLS="Read,Glob,Grep,Edit,MultiEdit,Write,\
Bash(git:*),Bash(npm:*),Bash(npx:*),Bash(node:*),\
Bash(python:*),Bash(python3:*),Bash(pip:*),\
Bash(cargo:*),Bash(go:*),Bash(make:*),\
Bash(yarn:*),Bash(pnpm:*),Bash(bun:*),Bash(deno:*),\
Bash(pytest:*),Bash(jest:*),Bash(tsc:*),Bash(eslint:*),Bash(prettier:*),\
Bash(bash:*),Bash(sh:*),Bash(source:*),Bash(rg:*),\
Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*),\
Bash(test:*),Bash(env:*),Bash(wc:*),Bash(head:*),Bash(tail:*),\
Bash(sed:*),Bash(awk:*),Bash(cut:*),Bash(tr:*),Bash(sort:*),Bash(uniq:*),\
Bash(xargs:*),Bash(printf:*),Bash(echo:*),Bash(pwd:*),Bash(date:*),\
Bash(chmod:*),Bash(mkdir:*),Bash(cp:*),Bash(mv:*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-30}"
    DEFAULT_MODEL="opus"
    ;;
  review)
    PERM_MODE="plan"
    ALLOWED_TOOLS="Read,Glob,Grep,WebFetch,\
Bash(git:*),Bash(curl:*),Bash(wget:*),\
Bash(ls:*),Bash(cat:*),Bash(wc:*),Bash(head:*),Bash(tail:*),\
Bash(env:*),Bash(pwd:*),Bash(date:*),Bash(find:*),Bash(echo:*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-15}"
    DEFAULT_MODEL="opus"
    ;;
  wide-open|root-wide|claws-wide)
    PERM_MODE="dontAsk"
    ALLOWED_TOOLS="Read,Glob,Grep,Edit,MultiEdit,Write,WebFetch,Bash(*)"
    MAX_TURNS="${EXTRA_MAX_TURNS:-25}"
    DEFAULT_MODEL="opus"
    ;;
  claws-out|unsafe)
    # keep `unsafe` as a compatibility alias
    if [[ "$PROFILE" == "unsafe" ]]; then
      echo "[foreman] NOTE: profile 'unsafe' is deprecated; use 'claws-out'" >&2
    fi
    PERM_MODE="bypassPermissions"
    ALLOWED_TOOLS=""
    MAX_TURNS="${EXTRA_MAX_TURNS:-20}"
    DEFAULT_MODEL="opus"
    ADD_GUARDRAIL=0
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

# Append guardrail to constrained profiles so runs end with a written summary.
if [[ "$ADD_GUARDRAIL" == "1" ]]; then
  FINAL_PROMPT="${PROMPT}${GUARDRAIL}"
else
  FINAL_PROMPT="$PROMPT"
fi

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

# --- Stream file (raw JSONL, per run) for auditability + liveness ---
mkdir -p "$STREAM_DIR"
STREAM_TS=$(date +%Y%m%d-%H%M%S)
STREAM_FILE="$STREAM_DIR/${STREAM_TS}-${PROFILE}.jsonl"
echo "[foreman] Stream: $STREAM_FILE"

# --- Build command ---
# Use stream-json so the raw event stream lands on disk (file mtime/last event =
# real liveness), while a compact filter emits tiny progress lines (no raw JSON
# spam). The final result is parsed from the last `type==result` event.
CMD=(
  claude
  -p "$FINAL_PROMPT"
  --model "$MODEL"
  --permission-mode "$PERM_MODE"
  --max-turns "$MAX_TURNS"
  --output-format stream-json
  --verbose
  --no-session-persistence
)

if [[ -n "$ALLOWED_TOOLS" ]]; then
  CMD+=(--allowedTools "$ALLOWED_TOOLS")
fi

if [[ -n "$WORKTREE" ]]; then
  CMD+=(--worktree)
fi

# --- Execute ---
TMPMETA=$(mktemp)
TMPERR=$(mktemp)
trap 'rm -f "$TMPMETA" "$TMPERR"' EXIT

cd "$TARGET_DIR"

# Pipe Claude's stdout through a filter that (a) writes every raw event line to
# the stream file and (b) emits compact, hard-truncated progress to stderr.
# Capture Claude's own exit status via PIPESTATUS (not the filter's) under
# set -euo pipefail by toggling errexit around the pipeline.
set +e
"${CMD[@]}" 2> "$TMPERR" | python3 -u -c '
import sys, json
stream_path = sys.argv[1]
SHORT = 100
def short(s):
    s = str(s).replace(chr(10), " ").replace(chr(13), " ").strip()
    return s[:SHORT] + ("..." if len(s) > SHORT else "")
def bash_hint(command):
    # Do not echo full shell commands; args can contain tokens or secrets.
    for part in str(command).replace(chr(10), " ").split():
        if "=" in part and not part.startswith(("/", "./", "../")):
            continue
        return part
    return "command"
def safe_target(value):
    # Strip query strings and fragments from URL-like values so tokens carried
    # in ?token=... or #... never leak into progress output.
    s = str(value)
    if "://" in s or s.startswith(("http:", "https:", "//", "www.")):
        for sep in ("?", "#"):
            cut = s.find(sep)
            if cut != -1:
                s = s[:cut] + " [args stripped]"
                break
    return s
def emit(msg):
    sys.stderr.write("[foreman:stream] " + msg + chr(10))
    sys.stderr.flush()
sf = open(stream_path, "w", buffering=1)
for line in iter(sys.stdin.readline, ""):
    sf.write(line)
    sf.flush()
    raw = line.strip()
    if not raw:
        continue
    try:
        ev = json.loads(raw)
    except Exception:
        continue
    t = ev.get("type")
    if t == "system" and ev.get("subtype") == "init":
        sid = str(ev.get("session_id", ""))[:8]
        emit("started session=" + sid + " model=" + str(ev.get("model", "")))
    elif t == "assistant":
        msg = ev.get("message", {}) or {}
        for block in (msg.get("content", []) or []):
            if isinstance(block, dict) and block.get("type") == "tool_use":
                name = block.get("name", "tool")
                inp = block.get("input", {})
                tgt = ""
                if isinstance(inp, dict):
                    if name == "Bash" and inp.get("command"):
                        tgt = bash_hint(inp.get("command"))
                    else:
                        for key in ("file_path", "path", "pattern", "url", "query"):
                            if inp.get(key):
                                tgt = safe_target(inp.get(key))
                                break
                    if not tgt:
                        for v in inp.values():
                            if isinstance(v, str) and v:
                                tgt = safe_target(v)
                                break
                emit("tool: " + str(name) + ((" " + short(tgt)) if tgt else ""))
    elif t == "user":
        msg = ev.get("message", {})
        blocks = msg.get("content", []) if isinstance(msg, dict) else []
        for block in (blocks or []):
            if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("is_error"):
                c = block.get("content", "")
                if isinstance(c, list):
                    c = " ".join(str(x.get("text", "")) for x in c if isinstance(x, dict))
                emit("tool-error: " + short(c))
    elif t == "result":
        ln = "result: subtype=" + str(ev.get("subtype", "")) + " turns=" + str(ev.get("num_turns", 0)) + " cost=$" + str(ev.get("total_cost_usd", 0))
        pd = len(ev.get("permission_denials", []) or [])
        if pd:
            ln += " permission_denials=" + str(pd)
        emit(ln)
sf.flush()
sf.close()
' "$STREAM_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

# --- Normalize the stream into a single metadata object (last result event) ---
# Produces a JSON with the same field names the downstream banner/cost-log code
# expects: result, total_cost_usd, num_turns, stop_reason, session_id,
# permission_denials, plus a found_result flag.
python3 -c '
import sys, json
stream_path, meta_path = sys.argv[1], sys.argv[2]
events = []
try:
    with open(stream_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except Exception:
                pass
except Exception:
    events = []
result_ev = None
last_assistant_stop = None
for e in events:
    if e.get("type") == "assistant":
        sr = (e.get("message", {}) or {}).get("stop_reason")
        if sr:
            last_assistant_stop = sr
    elif e.get("type") == "result":
        result_ev = e
if result_ev is None:
    out = {"result": "", "total_cost_usd": 0, "num_turns": 0,
           "stop_reason": "error", "session_id": "",
           "permission_denials": [], "found_result": False}
else:
    # Coerce subtype: the key may be present with a JSON null value, in which
    # case .get("subtype", "") returns None and None.startswith() would crash.
    sub = result_ev.get("subtype") or ""
    sr = result_ev.get("stop_reason")
    if sub in ("error_max_turns", "max_turns"):
        sr = "max_turns"
    elif sub.startswith("error") or result_ev.get("is_error"):
        sr = sr or "error"
    elif not sr:
        if last_assistant_stop:
            sr = last_assistant_stop
        elif sub == "success":
            sr = "end_turn"
        else:
            sr = "unknown"
    out = {"result": result_ev.get("result", ""),
           "total_cost_usd": result_ev.get("total_cost_usd", 0),
           "num_turns": result_ev.get("num_turns", 0),
           "stop_reason": sr,
           "session_id": result_ev.get("session_id", ""),
           "permission_denials": result_ev.get("permission_denials", []) or [],
           "found_result": True}
json.dump(out, open(meta_path, "w"))
' "$STREAM_FILE" "$TMPMETA"

# --- Parse normalized metadata ---
FOUND_RESULT=$(python3 -c "import json;print('1' if json.load(open('$TMPMETA')).get('found_result') else '0')" 2>/dev/null || echo "0")

RESULT_TEXT=$(python3 -c "
import json
try:
    d = json.load(open('$TMPMETA'))
    print(d.get('result', ''))
except:
    print('')
" 2>/dev/null || echo "")

COST=$(python3 -c "
import json
try:
    print(json.load(open('$TMPMETA')).get('total_cost_usd', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

NUM_TURNS=$(python3 -c "
import json
try:
    print(json.load(open('$TMPMETA')).get('num_turns', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

STOP_REASON=$(python3 -c "
import json
try:
    print(json.load(open('$TMPMETA')).get('stop_reason', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

SESSION_ID=$(python3 -c "
import json
try:
    print(json.load(open('$TMPMETA')).get('session_id', ''))
except:
    print('')
" 2>/dev/null || echo "")

PERM_DENIALS=$(python3 -c "
import json
try:
    print(len(json.load(open('$TMPMETA')).get('permission_denials', [])))
except:
    print(0)
" 2>/dev/null || echo "0")

if [[ "$FOUND_RESULT" != "1" ]]; then
  if [[ -z "${RESULT_TEXT//[[:space:]]/}" ]]; then
    RESULT_TEXT="(no result event — see stream file)"
  fi
  STOP_REASON="error"
fi

# --- Log cost ---
# All free-text and numeric values are passed through the environment instead of
# being interpolated into the Python source, so prompts/paths containing quotes,
# triple quotes, or backslashes can never break the script. Wrapped in `|| true`
# so a cost-log write failure can never abort the dispatch under `set -e`.
TASK_SUMMARY="${PROMPT:0:80}"
FOREMAN_COST_LOG="$COST_LOG" \
FOREMAN_PROFILE="$PROFILE" \
FOREMAN_MODEL="$MODEL" \
FOREMAN_NUM_TURNS="$NUM_TURNS" \
FOREMAN_MAX_TURNS="$MAX_TURNS" \
FOREMAN_COST="$COST" \
FOREMAN_STOP_REASON="$STOP_REASON" \
FOREMAN_PERM_DENIALS="$PERM_DENIALS" \
FOREMAN_SESSION_ID="$SESSION_ID" \
FOREMAN_TARGET="$TARGET_DIR" \
FOREMAN_TASK="$TASK_SUMMARY" \
python3 -c '
import json, os, time
def num(name, default=0):
    try:
        v = float(os.environ.get(name, "") or default)
        return int(v) if v == int(v) else v
    except Exception:
        return default
log_path = os.environ["FOREMAN_COST_LOG"]
try:
    entries = json.load(open(log_path))
    if not isinstance(entries, list):
        entries = []
except Exception:
    entries = []
entries.append({
    "timestamp": int(time.time()),
    "iso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "profile": os.environ.get("FOREMAN_PROFILE", ""),
    "model": os.environ.get("FOREMAN_MODEL", ""),
    "turns_used": num("FOREMAN_NUM_TURNS"),
    "max_turns": num("FOREMAN_MAX_TURNS"),
    "cost_usd": num("FOREMAN_COST"),
    "stop_reason": os.environ.get("FOREMAN_STOP_REASON", ""),
    "permission_denial_count": num("FOREMAN_PERM_DENIALS"),
    "session_id": os.environ.get("FOREMAN_SESSION_ID", ""),
    "target": os.environ.get("FOREMAN_TARGET", ""),
    "task": os.environ.get("FOREMAN_TASK", ""),
})
# Keep last 200 entries to prevent unbounded growth
entries = entries[-200:]
json.dump(entries, open(log_path, "w"), indent=2)
' || echo "[foreman] WARNING: cost-log write failed (continuing)." >&2

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

# --- Permission denial diagnostics ---
if [[ "$PERM_DENIALS" -gt 0 ]]; then
  echo "[foreman] Permission denials: $PERM_DENIALS" >&2
  python3 -c "
import json
try:
    d = json.load(open('$TMPMETA'))
    denials = d.get('permission_denials', [])
    for i, denial in enumerate(denials[:5]):
        tool = denial.get('tool', denial.get('tool_name', 'unknown'))
        tool_input = denial.get('tool_input', {})
        inp = denial.get('input') or denial.get('command') or denial.get('path')
        if inp is None and isinstance(tool_input, dict):
            inp = tool_input.get('command') or tool_input.get('path') or tool_input
        inp = str(inp or '')
        inp = inp[:180].replace('\n', ' ')
        print(f'  [{i+1}] {tool}: {inp}')
    if len(denials) > 5:
        print(f'  ... and {len(denials) - 5} more')
except Exception:
    pass
" >&2 || true
fi

if [[ "$STOP_REASON" == "max_turns" ]]; then
  echo "[foreman] WARNING: Hit turn limit -- task may be incomplete." >&2
fi

# --- Save artifacts for incomplete or problem runs ---
# The full raw stream always persists at $STREAM_FILE; here we additionally drop
# a labeled copy alongside other incomplete-run artifacts for easy triage.
SAVE_ARTIFACT=0
ARTIFACT_REASON=""

if [[ "$FOUND_RESULT" != "1" ]]; then
  SAVE_ARTIFACT=1
  ARTIFACT_REASON="no-result-event"
elif [[ "$STOP_REASON" == "tool_use" && -z "${RESULT_TEXT//[[:space:]]/}" ]]; then
  SAVE_ARTIFACT=1
  ARTIFACT_REASON="tool_use-no-result"
elif [[ "$STOP_REASON" == "max_turns" ]]; then
  SAVE_ARTIFACT=1
  ARTIFACT_REASON="max_turns"
elif [[ "$STOP_REASON" == "error" ]]; then
  SAVE_ARTIFACT=1
  ARTIFACT_REASON="error"
elif [[ "$PERM_DENIALS" -gt 0 ]]; then
  SAVE_ARTIFACT=1
  ARTIFACT_REASON="permission_denials"
fi

if [[ "$SAVE_ARTIFACT" == "1" ]]; then
  mkdir -p "$ARTIFACT_DIR"
  TS=$(date +%Y%m%d-%H%M%S)
  OUT_ARTIFACT="$ARTIFACT_DIR/incomplete-${TS}-${PROFILE}-${ARTIFACT_REASON}.jsonl"
  ERR_ARTIFACT="$ARTIFACT_DIR/incomplete-${TS}-${PROFILE}-${ARTIFACT_REASON}.stderr"
  cp "$STREAM_FILE" "$OUT_ARTIFACT" 2>/dev/null || true
  cp "$TMPERR" "$ERR_ARTIFACT" 2>/dev/null || true
  echo "[foreman] Artifacts saved: $OUT_ARTIFACT" >&2
  echo "[foreman] Raw stream: $STREAM_FILE" >&2

  if [[ "$ARTIFACT_REASON" == "tool_use-no-result" ]]; then
    echo "[foreman] WARNING: Claude stopped at tool_use before writing a result." >&2
    echo "[foreman] Tip: re-dispatch with more turns and add: 'End with a written summary even if you must stop inspecting files.'" >&2
  elif [[ "$ARTIFACT_REASON" == "no-result-event" ]]; then
    echo "[foreman] WARNING: No 'result' event in the stream (process killed/crashed before completion?)." >&2
    echo "[foreman] Tip: suspect a wrapper timeout or CLI error; check the stream tail and stderr below." >&2
  fi

  # NOTE: we deliberately do NOT echo a raw stream tail here. The stream file
  # contains raw JSON events (thinking blocks, signatures, tool I/O) that would
  # bloat and pollute the parent tool output, especially on permission denials.
  # The full stream is preserved on disk at the paths printed above for triage.
  if [[ -s "$STREAM_FILE" ]]; then
    STREAM_LINES=$(wc -l < "$STREAM_FILE" 2>/dev/null | tr -d ' ' || echo "?")
    echo "[foreman] Raw stream preserved on disk ($STREAM_LINES events): $STREAM_FILE" >&2
    echo "[foreman] Inspect with: tail -n 20 \"$STREAM_FILE\"" >&2
  fi
fi

# --- Retention: prune old stream files (keep newest $STREAM_KEEP) ---
python3 -c "
import os, glob
files = sorted(glob.glob(os.path.join('$STREAM_DIR', '*.jsonl')), key=os.path.getmtime)
for f in files[:-$STREAM_KEEP]:
    try:
        os.remove(f)
    except Exception:
        pass
" 2>/dev/null || true

if [[ -s "$TMPERR" ]]; then
  echo "[foreman] Stderr:" >&2
  cat "$TMPERR" >&2
fi

# --- Output result ---
echo ""
echo "$RESULT_TEXT"

exit "$EXIT_CODE"
