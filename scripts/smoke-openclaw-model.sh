#!/usr/bin/env bash
# Live OpenClaw model-provider smoke.
# Proves a selectable provider/model ref can return actual response text through
# the OpenClaw agent pipeline. This matters for CLI backends because direct
# `openclaw infer model run` exercises provider transports, not agent runtimes.

set -euo pipefail

SCRIPT_SRC="$0"
if command -v readlink >/dev/null 2>&1; then
  SCRIPT_SRC="$(readlink -f "$0" 2>/dev/null || echo "$0")"
elif command -v realpath >/dev/null 2>&1; then
  SCRIPT_SRC="$(realpath "$0" 2>/dev/null || echo "$0")"
fi
SKILL_DIR="$(cd "$(dirname "$SCRIPT_SRC")/.." && pwd)"

MODEL=""
PROMPT=""
TIMEOUT_SECONDS=240
SESSION_KEY=""

usage() {
  cat <<'USAGE'
Usage: smoke-openclaw-model.sh --model <provider/model> [options]

Options:
  --model <provider/model>  Model ref exactly as shown by `openclaw models list`.
  --prompt <text>           Prompt to send. Default: unique exact-reply sentinel
  --timeout <seconds>       Live command timeout. Default: 240
  --session-key <key>       OpenClaw local session key. Default: generated smoke key

The script saves raw JSON/text output under artifacts/smokes and prints the
parsed response text when available.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="${2:?missing --model value}"
      shift 2
      ;;
    --prompt)
      PROMPT="${2:?missing --prompt value}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:?missing --timeout value}"
      shift 2
      ;;
    --session-key)
      SESSION_KEY="${2:?missing --session-key value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[smoke] Unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for _bin in openclaw python3; do
  if ! command -v "$_bin" >/dev/null 2>&1; then
    echo "[smoke] Required command not found in PATH: $_bin" >&2
    exit 1
  fi
done

if [[ -z "$MODEL" ]]; then
  echo "[smoke] Missing --model <provider/model>." >&2
  exit 1
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ARTIFACT_DIR="$SKILL_DIR/artifacts/smokes"
mkdir -p "$ARTIFACT_DIR"
OUT_FILE="$ARTIFACT_DIR/${RUN_ID}.openclaw-model.json"
ERR_FILE="$ARTIFACT_DIR/${RUN_ID}.openclaw-model.stderr"
SESSION_KEY="${SESSION_KEY:-agent:main:foreman-openclaw-smoke-${RUN_ID}}"

if [[ -z "$PROMPT" ]]; then
  SAFE_MODEL="${MODEL//[^A-Za-z0-9_]/_}"
  PROMPT="Reply exactly: OPENCLAW_MODEL_SMOKE_${SAFE_MODEL}_${RUN_ID}"
fi

echo "[smoke] model=$MODEL"
echo "[smoke] output=$OUT_FILE"
echo "[smoke] session_key=$SESSION_KEY"
echo "[smoke] prompt=$PROMPT"

CMD=(
  openclaw agent
  --local
  --json
  --session-key "$SESSION_KEY"
  --model "$MODEL"
  --message "$PROMPT"
  --timeout "$TIMEOUT_SECONDS"
)

set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "$TIMEOUT_SECONDS" "${CMD[@]}" >"$OUT_FILE" 2>"$ERR_FILE"
else
  "${CMD[@]}" >"$OUT_FILE" 2>"$ERR_FILE"
fi
EXIT_CODE=$?
set -e

RESULT_TEXT=$(python3 -c '
import json, sys
path, err_path = sys.argv[1], sys.argv[2]
try:
    raw = open(path).read()
except FileNotFoundError:
    raw = ""
text = ""
try:
    data = json.loads(raw)
    def walk(o):
        if isinstance(o, dict):
            for key in ("text", "content", "message", "reply", "output", "result"):
                v = o.get(key)
                if isinstance(v, str) and v.strip():
                    return v
            for v in o.values():
                got = walk(v)
                if got:
                    return got
        elif isinstance(o, list):
            for v in o:
                got = walk(v)
                if got:
                    return got
        return ""
    text = walk(data)
except Exception:
    text = raw.strip()
if not text.strip():
    try:
        err = open(err_path).read()
    except FileNotFoundError:
        err = ""
    for marker in ("FailoverError:", "Error:"):
        if marker in err:
            text = err.rsplit(marker, 1)[-1].strip().splitlines()[0].strip()
            break
print(text)
' "$OUT_FILE" "$ERR_FILE")

echo "[smoke] exit_code=$EXIT_CODE"
echo "[smoke] result=$RESULT_TEXT"

if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo "[smoke] FAIL: openclaw exited $EXIT_CODE; stderr=$ERR_FILE" >&2
  exit "$EXIT_CODE"
fi
if [[ -z "${RESULT_TEXT//[[:space:]]/}" ]]; then
  echo "[smoke] FAIL: no non-empty result text parsed from output." >&2
  exit 1
fi

echo "[smoke] PASS"
