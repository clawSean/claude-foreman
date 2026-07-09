#!/usr/bin/env bash
# Live Claude CLI profile smoke.
# Proves a named profile can authenticate from the env var listed in
# claude-profiles.json and returns actual result text from Claude.

set -euo pipefail

SCRIPT_SRC="$0"
if command -v readlink >/dev/null 2>&1; then
  SCRIPT_SRC="$(readlink -f "$0" 2>/dev/null || echo "$0")"
elif command -v realpath >/dev/null 2>&1; then
  SCRIPT_SRC="$(realpath "$0" 2>/dev/null || echo "$0")"
fi
SKILL_DIR="$(cd "$(dirname "$SCRIPT_SRC")/.." && pwd)"

PROFILES_FILE="${FOREMAN_CLAUDE_PROFILES_FILE:-${CLAUDE_PROFILES_FILE:-/root/.openclaw/claude-profiles.json}}"
PROFILE=""
MODEL="sonnet"
PROMPT=""
TIMEOUT_SECONDS=180

usage() {
  cat <<'USAGE'
Usage: smoke-claude-profile.sh --profile <name> [options]

Options:
  --profile <name>        Profile key from claude-profiles.json.
  --profiles-file <path>  Profile JSON path. Default: /root/.openclaw/claude-profiles.json
  --model <model>         Claude model alias/id. Default: sonnet
  --prompt <text>         Prompt to send. Default: unique exact-reply sentinel
  --timeout <seconds>     Live command timeout. Default: 180

The script prints the selected profile, env var name, stream path, Claude init
model, exit code, and parsed result text. It never prints token values.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing --profile value}"
      shift 2
      ;;
    --profiles-file)
      PROFILES_FILE="${2:?missing --profiles-file value}"
      shift 2
      ;;
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

for _bin in claude python3; do
  if ! command -v "$_bin" >/dev/null 2>&1; then
    echo "[smoke] Required command not found in PATH: $_bin" >&2
    exit 1
  fi
done

if [[ -z "$PROFILE" ]]; then
  PROFILE="$(python3 -c '
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("active") or "").strip())
except Exception:
    print("")
' "$PROFILES_FILE")"
fi
if [[ -z "$PROFILE" ]]; then
  echo "[smoke] No profile selected. Pass --profile <name>." >&2
  exit 1
fi
if [[ ! -f "$PROFILES_FILE" ]]; then
  echo "[smoke] Profiles file not found: $PROFILES_FILE" >&2
  exit 1
fi

PROFILE_META=$(python3 -c '
import json, sys
profiles_file, profile = sys.argv[1], sys.argv[2]
data = json.load(open(profiles_file))
entry = (data.get("profiles") or {}).get(profile)
if not isinstance(entry, dict):
    raise SystemExit("unknown profile: " + profile)
env_var = str(entry.get("env_var") or "").strip()
label = str(entry.get("label") or profile).strip()
if not env_var:
    raise SystemExit("profile has no env_var: " + profile)
print(env_var + "\x1f" + label)
' "$PROFILES_FILE" "$PROFILE")
IFS=$'\x1f' read -r TOKEN_ENV_VAR PROFILE_LABEL <<< "$PROFILE_META"

if [[ ! "$TOKEN_ENV_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "[smoke] Profile '$PROFILE' uses invalid env_var '$TOKEN_ENV_VAR'." >&2
  echo "[smoke] Env var names must match [A-Za-z_][A-Za-z0-9_]*." >&2
  exit 1
fi

TOKEN="${!TOKEN_ENV_VAR:-}"
if [[ -z "$TOKEN" ]]; then
  echo "[smoke] Profile '$PROFILE' expects token env var \$$TOKEN_ENV_VAR, but it is empty." >&2
  exit 1
fi
export CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-${PROFILE}"
ARTIFACT_DIR="$SKILL_DIR/artifacts/smokes"
mkdir -p "$ARTIFACT_DIR"
STREAM_FILE="$ARTIFACT_DIR/${RUN_ID}.stream.jsonl"
ERR_FILE="$ARTIFACT_DIR/${RUN_ID}.stderr"

if [[ -z "$PROMPT" ]]; then
  PROMPT="Reply exactly: FOREMAN_PROFILE_SMOKE_${PROFILE}_${RUN_ID}"
fi

echo "[smoke] profile=$PROFILE label=$PROFILE_LABEL env=\$$TOKEN_ENV_VAR model=$MODEL"
echo "[smoke] stream=$STREAM_FILE"
echo "[smoke] prompt=$PROMPT"

CMD=(
  claude
  -p "$PROMPT"
  --model "$MODEL"
  --output-format stream-json
  --verbose
  --no-session-persistence
)

set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "$TIMEOUT_SECONDS" "${CMD[@]}" >"$STREAM_FILE" 2>"$ERR_FILE"
else
  "${CMD[@]}" >"$STREAM_FILE" 2>"$ERR_FILE"
fi
EXIT_CODE=$?
set -e

SUMMARY=$(python3 -c '
import json, sys
stream = sys.argv[1]
init_model = ""
session = ""
result = ""
stop = ""
cost = 0
turns = 0
found = False
try:
    for line in open(stream):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            init_model = str(ev.get("model") or "")
            session = str(ev.get("session_id") or session)
        elif ev.get("type") == "result":
            found = True
            result = str(ev.get("result") or "")
            stop = str(ev.get("stop_reason") or ev.get("subtype") or "")
            cost = ev.get("total_cost_usd") or 0
            turns = ev.get("num_turns") or 0
            session = str(ev.get("session_id") or session)
except FileNotFoundError:
    pass
print(json.dumps({
    "found": found,
    "init_model": init_model,
    "session_id": session,
    "stop_reason": stop,
    "turns": turns,
    "cost_usd": cost,
    "result": result,
}))
' "$STREAM_FILE")

python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print("[smoke] init_model=" + str(d.get("init_model") or ""))
print("[smoke] session=" + str(d.get("session_id") or ""))
print("[smoke] stop_reason=" + str(d.get("stop_reason") or ""))
print("[smoke] turns=" + str(d.get("turns") or 0) + " cost=$" + str(d.get("cost_usd") or 0))
print("[smoke] result=" + str(d.get("result") or ""))
' "$SUMMARY"

FOUND=$(python3 -c 'import json,sys; print("1" if json.loads(sys.argv[1]).get("found") else "0")' "$SUMMARY")
RESULT_TEXT=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("result") or "")' "$SUMMARY")

if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo "[smoke] FAIL: claude exited $EXIT_CODE; stderr=$ERR_FILE" >&2
  exit "$EXIT_CODE"
fi
if [[ "$FOUND" != "1" || -z "${RESULT_TEXT//[[:space:]]/}" ]]; then
  echo "[smoke] FAIL: no non-empty result text parsed from stream." >&2
  exit 1
fi

echo "[smoke] PASS"
