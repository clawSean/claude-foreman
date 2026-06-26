#!/usr/bin/env bash
# claude-foreman dispatch script
# Usage: dispatch.sh <profile> <target_dir> "<prompt>" [extra_flags...]
#
# Profiles: plan, implement, review, wide-open, claws-out (legacy alias: unsafe)
# Extra flags: --model sonnet, --effort max, --worktree, --force, --max-turns N,
#              --provider claude-cli|claude-work, --profile <name>,
#              --no-profile-fallback

set -euo pipefail

# --- Pre-flight: required binaries must be on PATH ---
# Checked up front so a missing dependency produces an obvious error instead of
# failing deep inside the dispatch pipeline (where the real cause gets masked by
# an empty stream / "no result event" diagnostic).
for _bin in claude python3; do
  if ! command -v "$_bin" >/dev/null 2>&1; then
    echo "[foreman] Required command not found in PATH: $_bin" >&2
    echo "[foreman] Install it or fix PATH before dispatching." >&2
    exit 1
  fi
done

# --- Resolve script location through symlinks ---
# dirname "$0" alone breaks when dispatch.sh is invoked via a symlink: the cost
# log, artifacts, and stream dirs would resolve relative to the link's location
# instead of the real skill dir. Resolve the canonical path first.
SCRIPT_SRC="$0"
if command -v readlink >/dev/null 2>&1; then
  SCRIPT_SRC="$(readlink -f "$0" 2>/dev/null || echo "$0")"
elif command -v realpath >/dev/null 2>&1; then
  SCRIPT_SRC="$(realpath "$0" 2>/dev/null || echo "$0")"
fi

SKILL_DIR="$(cd "$(dirname "$SCRIPT_SRC")/.." && pwd)"
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
EFFORT=""
WORKTREE=""
FORCE=""
EXTRA_MAX_TURNS=""
PROVIDER=""
AUTH_PROFILE=""
AUTH_PROFILE_EXPLICIT=""
LANE_REQUESTED=""
PROFILE_FALLBACK_DISABLED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --effort)
      EFFORT="$2"
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
    --provider)
      PROVIDER="$2"
      LANE_REQUESTED=1
      shift 2
      ;;
    --profile)
      AUTH_PROFILE="$2"
      AUTH_PROFILE_EXPLICIT=1
      LANE_REQUESTED=1
      shift 2
      ;;
    --no-profile-fallback)
      PROFILE_FALLBACK_DISABLED=1
      shift
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

# --- Pre-flight: --worktree requires a git work tree ---
# Without this check, passing --worktree against a non-git directory fails deep
# in the Claude CLI and the error gets wrapped in the stream-artifact diagnostic
# instead of a clear up-front message.
if [[ -n "$WORKTREE" ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "[foreman] --worktree requires git, which is not on PATH." >&2
    exit 1
  fi
  if ! git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[foreman] --worktree requested but target is not a git work tree: $TARGET_DIR" >&2
    echo "[foreman] Run inside a git repo, or drop --worktree." >&2
    exit 1
  fi
fi

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

# --- Provider / auth-lane selection (optional) ---
# dispatch.sh shells out to the `claude` binary, which authenticates via the
# CLAUDE_CODE_OAUTH_TOKEN env var. With no provider/profile flag we preserve
# normal Foreman behavior and inherit whatever Claude auth the caller already
# has. When the caller enters the profile-aware claude-cli lane, Foreman orders
# profiles from claude-profiles.json, starts with the active profile, and falls
# forward on opening-request quota errors. Explicit --profile runs stay strict.
CLAUDE_PROFILES_FILE="${FOREMAN_CLAUDE_PROFILES_FILE:-${CLAUDE_PROFILES_FILE:-/root/.openclaw/claude-profiles.json}}"
CLAUDE_PROFILE_STATE="${FOREMAN_CLAUDE_PROFILE_STATE:-${CLAUDE_AUTH_ACTIVE_FILE:-/root/.openclaw/claude-auth-active}}"
AUTH_PROFILE_COOLDOWN_SECONDS="${FOREMAN_CLAUDE_PROFILE_COOLDOWN_SECONDS:-300}"
AUTH_FALLBACK_MODE="ambient"
AUTH_CANDIDATE_NAMES=()
AUTH_CANDIDATE_LABELS=()
AUTH_CANDIDATE_ENV_VARS=()
AUTH_CANDIDATE_COOLDOWNS=()
LANE_DESC="inherited (ambient claude auth)"
AUTH_AUTO_DETECTED=""

if [[ -z "$LANE_REQUESTED" && -z "$PROFILE_FALLBACK_DISABLED" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -f "$CLAUDE_PROFILES_FILE" ]]; then
  AUTO_USABLE_PROFILE_COUNT="$(
    FOREMAN_CLAUDE_PROFILES_FILE="$CLAUDE_PROFILES_FILE" \
    FOREMAN_CLAUDE_PROFILE_STATE="$CLAUDE_PROFILE_STATE" \
      python3 - <<'PY'
import json, os, re

profiles_file = os.environ["FOREMAN_CLAUDE_PROFILES_FILE"]
state_file = os.environ["FOREMAN_CLAUDE_PROFILE_STATE"]
env_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

try:
    with open(profiles_file) as fh:
        data = json.load(fh)
except Exception:
    print(0)
    raise SystemExit(0)

profiles = data.get("profiles") or {}
if not isinstance(profiles, dict) or not profiles:
    print(0)
    raise SystemExit(0)

def read_active():
    try:
        with open(state_file) as fh:
            active = fh.read().strip()
            if active:
                return active
    except Exception:
        pass
    return str(data.get("active") or "").strip()

active = read_active()
names = []
if active and active in profiles:
    names.append(active)
for name in profiles.keys():
    if name not in names:
        names.append(name)

usable = []
for name in names:
    entry = profiles.get(name)
    if not isinstance(entry, dict):
        continue
    env_var = str(entry.get("env_var") or "").strip()
    if not env_var or not env_re.match(env_var):
        continue
    if os.environ.get(env_var):
        usable.append(name)

print(len(usable))
PY
  )"
  if [[ "$AUTO_USABLE_PROFILE_COUNT" =~ ^[0-9]+$ && "$AUTO_USABLE_PROFILE_COUNT" -ge 2 ]]; then
    PROVIDER="claude-cli"
    LANE_REQUESTED=1
    AUTH_AUTO_DETECTED=1
  fi
fi

if [[ -n "$LANE_REQUESTED" ]]; then
  if [[ ! "$AUTH_PROFILE_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "[foreman] FOREMAN_CLAUDE_PROFILE_COOLDOWN_SECONDS must be an integer number of seconds." >&2
    exit 1
  fi
  case "$PROVIDER" in
    claude-work)
      AUTH_PROFILE="${AUTH_PROFILE:-work}"
      AUTH_FALLBACK_MODE="strict"
      ;;
    claude-cli|"")
      if [[ -n "$AUTH_PROFILE_EXPLICIT" || -n "$PROFILE_FALLBACK_DISABLED" ]]; then
        AUTH_FALLBACK_MODE="strict"
        if [[ -z "$AUTH_PROFILE" ]]; then
          AUTH_PROFILE="$(cat "$CLAUDE_PROFILE_STATE" 2>/dev/null || true)"
          AUTH_PROFILE="${AUTH_PROFILE//[$'\t\r\n ']}"
        fi
        if [[ -z "$AUTH_PROFILE" ]]; then
          AUTH_PROFILE="$(python3 -c '
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("active") or "").strip())
except Exception:
    print("")
' "$CLAUDE_PROFILES_FILE")"
        fi
      else
        AUTH_FALLBACK_MODE="fallback"
      fi
      ;;
    *)
      echo "[foreman] Unknown provider: $PROVIDER (use: claude-cli, claude-work)" >&2
      exit 1
      ;;
  esac
  if [[ "$AUTH_FALLBACK_MODE" == "strict" && -z "$AUTH_PROFILE" ]]; then
    echo "[foreman] No Claude auth profile selected. Pass --profile <name> or set active in $CLAUDE_PROFILE_STATE / $CLAUDE_PROFILES_FILE." >&2
    exit 1
  fi
  if [[ ! -f "$CLAUDE_PROFILES_FILE" ]]; then
    echo "[foreman] Claude profiles file not found: $CLAUDE_PROFILES_FILE" >&2
    echo "[foreman] Either omit --profile/--provider to inherit ambient auth, or create a profiles JSON file." >&2
    exit 1
  fi
  PROFILE_META=$(FOREMAN_CLAUDE_PROFILES_FILE="$CLAUDE_PROFILES_FILE" \
    FOREMAN_CLAUDE_PROFILE_STATE="$CLAUDE_PROFILE_STATE" \
    FOREMAN_AUTH_FALLBACK_MODE="$AUTH_FALLBACK_MODE" \
    FOREMAN_AUTH_PROFILE="$AUTH_PROFILE" \
    python3 - <<'PY'
import json, os, re, sys, time

sep = "\x1f"

def clean(value):
    return str(value or "").replace(sep, " ").replace("\n", " ").replace("\r", " ").strip()

def line(kind, *fields):
    print(sep.join([kind, *[clean(f) for f in fields]]))

profiles_file = os.environ["FOREMAN_CLAUDE_PROFILES_FILE"]
state_file = os.environ["FOREMAN_CLAUDE_PROFILE_STATE"]
mode = os.environ.get("FOREMAN_AUTH_FALLBACK_MODE", "strict")
requested = os.environ.get("FOREMAN_AUTH_PROFILE", "").strip()
env_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

try:
    with open(profiles_file) as fh:
        data = json.load(fh)
except Exception as exc:
    line("ERROR", f"Cannot read {profiles_file}: {exc}")
    sys.exit(0)
profiles = data.get("profiles") or {}
if not isinstance(profiles, dict) or not profiles:
    line("ERROR", f"No profiles found in {profiles_file}")
    sys.exit(0)

def read_active():
    try:
        with open(state_file) as fh:
            active = fh.read().strip()
            if active:
                return active
    except Exception:
        pass
    return str(data.get("active") or "").strip()

def cooldown_until(entry):
    try:
        return int(float(entry.get("cooldown_until") or 0))
    except Exception:
        return 0

def validate_profile(name):
    entry = profiles.get(name)
    if not isinstance(entry, dict):
        return None, f"Unknown Claude profile: {name}"
    env_var = str(entry.get("env_var") or "").strip()
    label = str(entry.get("label") or name).strip()
    if not env_var:
        return None, f"Claude profile has no env_var: {name}"
    if not env_re.match(env_var):
        return None, f"Claude profile '{name}' uses invalid env_var '{env_var}'. Env var names must match [A-Za-z_][A-Za-z0-9_]*."
    if not os.environ.get(env_var):
        return None, f"Requested auth lane profile='{name}' but its token env var is empty. Expected a token in ${env_var}"
    return (name, label or name, env_var, cooldown_until(entry)), None

if mode == "strict":
    candidate, err = validate_profile(requested)
    if err:
        line("ERROR", err)
    else:
        line("CAND", *candidate)
    sys.exit(0)

active = read_active()
names = []
if active and active in profiles:
    names.append(active)
elif active:
    line("WARN", f"Active Claude profile '{active}' is not present in {profiles_file}; falling back to file order")
for name in profiles.keys():
    if name not in names:
        names.append(name)

now = int(time.time())
usable = []
for name in names:
    candidate, err = validate_profile(name)
    if err:
        line("WARN", err)
        continue
    usable.append(candidate)

if not usable:
    line("ERROR", f"No usable Claude profiles found in {profiles_file}. Check env_var names and exported token variables.")
    sys.exit(0)

healthy = [c for c in usable if c[3] <= now]
cooling = [c for c in usable if c[3] > now]
for candidate in healthy + cooling:
    line("CAND", *candidate)
PY
  )
  while IFS=$'\x1f' read -r META_KIND META_NAME META_LABEL META_ENV META_COOLDOWN; do
    [[ -n "$META_KIND" ]] || continue
    case "$META_KIND" in
      CAND)
        AUTH_CANDIDATE_NAMES+=("$META_NAME")
        AUTH_CANDIDATE_LABELS+=("$META_LABEL")
        AUTH_CANDIDATE_ENV_VARS+=("$META_ENV")
        AUTH_CANDIDATE_COOLDOWNS+=("${META_COOLDOWN:-0}")
        ;;
      WARN)
        echo "[foreman] WARNING: $META_NAME" >&2
        ;;
      ERROR)
        echo "[foreman] $META_NAME" >&2
        echo "[foreman] Profiles file: $CLAUDE_PROFILES_FILE" >&2
        exit 1
        ;;
    esac
  done <<< "$PROFILE_META"

  if [[ "${#AUTH_CANDIDATE_NAMES[@]}" -eq 0 ]]; then
    echo "[foreman] No Claude auth profiles were usable." >&2
    echo "[foreman] Profiles file: $CLAUDE_PROFILES_FILE" >&2
    exit 1
  fi

  if [[ "$AUTH_FALLBACK_MODE" == "strict" ]]; then
    LANE_DESC="${PROVIDER:-claude-cli} (${AUTH_CANDIDATE_NAMES[0]}; env \$${AUTH_CANDIDATE_ENV_VARS[0]})"
  else
    PROFILE_ORDER="${AUTH_CANDIDATE_NAMES[0]}"
    for ((i = 1; i < ${#AUTH_CANDIDATE_NAMES[@]}; i++)); do
      PROFILE_ORDER+=" -> ${AUTH_CANDIDATE_NAMES[$i]}"
    done
    LANE_DESC="${PROVIDER:-claude-cli} fallback ($PROFILE_ORDER)"
    if [[ -n "$AUTH_AUTO_DETECTED" ]]; then
      LANE_DESC+=" [auto-detected]"
    fi
  fi
fi

mark_auth_profile_cooldown() {
  local profile="$1"
  local reason="$2"
  local error_text="$3"

  [[ -f "$CLAUDE_PROFILES_FILE" ]] || return 0
  (
    flock -w 10 9 2>/dev/null || true
    FOREMAN_CLAUDE_PROFILES_FILE="$CLAUDE_PROFILES_FILE" \
    FOREMAN_AUTH_PROFILE="$profile" \
    FOREMAN_COOLDOWN_SECONDS="$AUTH_PROFILE_COOLDOWN_SECONDS" \
    FOREMAN_COOLDOWN_REASON="$reason" \
    FOREMAN_COOLDOWN_ERROR="$error_text" \
    python3 - <<'PY'
import json, os, time

path = os.environ["FOREMAN_CLAUDE_PROFILES_FILE"]
profile = os.environ["FOREMAN_AUTH_PROFILE"]
seconds = int(os.environ.get("FOREMAN_COOLDOWN_SECONDS") or "300")
reason = os.environ.get("FOREMAN_COOLDOWN_REASON", "rate_limit")
error = (os.environ.get("FOREMAN_COOLDOWN_ERROR", "") or "").replace("\n", " ").strip()[:240]
now = int(time.time())

try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(0)

profiles = data.get("profiles")
entry = profiles.get(profile) if isinstance(profiles, dict) else None
if not isinstance(entry, dict):
    raise SystemExit(0)

entry["cooldown_until"] = now + seconds
entry["cooldown_reason"] = reason
entry["last_failed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
if error:
    entry["last_error"] = error

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
  ) 9>"$CLAUDE_PROFILES_FILE.lock" || echo "[foreman] WARNING: failed to update Claude profile cooldown for $profile" >&2
}

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
if [[ -n "$AUTH_AUTO_DETECTED" ]]; then
  echo "[foreman] Auto-detected ${#AUTH_CANDIDATE_NAMES[@]} usable Claude profiles; using profile fallback lane."
fi
echo "[foreman] Auth lane: $LANE_DESC"
if [[ -n "$EFFORT" ]]; then
  echo "[foreman] Effort: $EFFORT"
fi
if [[ "$ORIGINAL_TARGET_DIR" != "$TARGET_DIR" ]]; then
  echo "[foreman] Target: $ORIGINAL_TARGET_DIR -> $TARGET_DIR"
else
  echo "[foreman] Target: $TARGET_DIR"
fi
echo "[foreman] Prompt: ${PROMPT:0:120}..."

# --- Stream file (raw JSONL, per run) for auditability + liveness ---
mkdir -p "$STREAM_DIR"
# Include the PID so two dispatches started in the same second (scripted
# fan-out) can't overwrite each other's stream file.
STREAM_TS=$(date +%Y%m%d-%H%M%S)
STREAM_FILE=""

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

if [[ -n "$EFFORT" ]]; then
  CMD+=(--effort "$EFFORT")
fi

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

AUTH_ATTEMPT_TOTAL=1
if [[ "$AUTH_FALLBACK_MODE" != "ambient" ]]; then
  AUTH_ATTEMPT_TOTAL="${#AUTH_CANDIDATE_NAMES[@]}"
fi
AUTH_ATTEMPT_PROFILE=""
AUTH_ATTEMPT_LABEL=""
AUTH_ATTEMPT_ENV_VAR=""
AUTH_ATTEMPT_INDEX=0
EXIT_CODE=0

for ((AUTH_ATTEMPT_INDEX = 0; AUTH_ATTEMPT_INDEX < AUTH_ATTEMPT_TOTAL; AUTH_ATTEMPT_INDEX++)); do
  : > "$TMPMETA"
  : > "$TMPERR"

  AUTH_SUFFIX="-ambient-a1"
  if [[ "$AUTH_FALLBACK_MODE" != "ambient" ]]; then
    AUTH_ATTEMPT_PROFILE="${AUTH_CANDIDATE_NAMES[$AUTH_ATTEMPT_INDEX]}"
    AUTH_ATTEMPT_LABEL="${AUTH_CANDIDATE_LABELS[$AUTH_ATTEMPT_INDEX]}"
    AUTH_ATTEMPT_ENV_VAR="${AUTH_CANDIDATE_ENV_VARS[$AUTH_ATTEMPT_INDEX]}"
    AUTH_TOKEN="${!AUTH_ATTEMPT_ENV_VAR:-}"
    if [[ -z "$AUTH_TOKEN" ]]; then
      echo "[foreman] Auth profile '$AUTH_ATTEMPT_PROFILE' lost its token before dispatch; expected \$$AUTH_ATTEMPT_ENV_VAR." >&2
      exit 1
    fi
    export CLAUDE_CODE_OAUTH_TOKEN="$AUTH_TOKEN"
    AUTH_SUFFIX="-${AUTH_ATTEMPT_PROFILE}-a$((AUTH_ATTEMPT_INDEX + 1))"
    if [[ "$AUTH_ATTEMPT_TOTAL" -gt 1 ]]; then
      echo "[foreman] Auth attempt $((AUTH_ATTEMPT_INDEX + 1))/$AUTH_ATTEMPT_TOTAL: $AUTH_ATTEMPT_PROFILE ($AUTH_ATTEMPT_LABEL; env \$$AUTH_ATTEMPT_ENV_VAR)"
    fi
  fi

  STREAM_FILE="$STREAM_DIR/${STREAM_TS}-$$-${PROFILE}${AUTH_SUFFIX}.jsonl"
  echo "[foreman] Stream: $STREAM_FILE"

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
assistant_errors = []
tool_use_count = 0
for e in events:
    if e.get("type") == "assistant":
        if e.get("error"):
            assistant_errors.append(str(e.get("error")))
        sr = (e.get("message", {}) or {}).get("stop_reason")
        if sr:
            last_assistant_stop = sr
        msg = e.get("message", {}) or {}
        for block in (msg.get("content", []) or []):
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_use_count += 1
    elif e.get("type") == "result":
        result_ev = e
if result_ev is None:
    out = {"result": "", "total_cost_usd": 0, "num_turns": 0,
           "stop_reason": "error", "session_id": "",
           "permission_denials": [], "found_result": False,
           "is_error": False, "api_error_status": "",
           "assistant_error": assistant_errors[-1] if assistant_errors else "",
           "tool_use_count": tool_use_count,
           "usage_input_tokens": 0, "usage_output_tokens": 0}
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
    usage = result_ev.get("usage") or {}
    if not isinstance(usage, dict):
        usage = {}
    out = {"result": result_ev.get("result", ""),
           "total_cost_usd": result_ev.get("total_cost_usd", 0),
           "num_turns": result_ev.get("num_turns", 0),
           "stop_reason": sr,
           "session_id": result_ev.get("session_id", ""),
           "permission_denials": result_ev.get("permission_denials", []) or [],
           "found_result": True,
           "is_error": bool(result_ev.get("is_error")),
           "api_error_status": result_ev.get("api_error_status", ""),
           "assistant_error": assistant_errors[-1] if assistant_errors else "",
           "tool_use_count": tool_use_count,
           "usage_input_tokens": usage.get("input_tokens", 0) or 0,
           "usage_output_tokens": usage.get("output_tokens", 0) or 0}
json.dump(out, open(meta_path, "w"))
' "$STREAM_FILE" "$TMPMETA"

  if [[ "$AUTH_FALLBACK_MODE" == "fallback" && "$AUTH_ATTEMPT_INDEX" -lt $((AUTH_ATTEMPT_TOTAL - 1)) ]]; then
    RETRY_META=$(FOREMAN_META_FILE="$TMPMETA" FOREMAN_STDERR_FILE="$TMPERR" python3 - <<'PY'
import json, os, re

sep = "\x1f"
try:
    with open(os.environ["FOREMAN_META_FILE"]) as fh:
        d = json.load(fh)
except Exception:
    d = {}
try:
    with open(os.environ["FOREMAN_STDERR_FILE"]) as fh:
        stderr = fh.read()
except Exception:
    stderr = ""

def num(value):
    try:
        return float(value or 0)
    except Exception:
        return 0.0

api_status = str(d.get("api_error_status") or "")
assistant_error = str(d.get("assistant_error") or "")
tool_uses = int(num(d.get("tool_use_count")))
input_tokens = int(num(d.get("usage_input_tokens")))
output_tokens = int(num(d.get("usage_output_tokens")))
cost = num(d.get("total_cost_usd"))
is_error = bool(d.get("is_error"))
result = str(d.get("result") or "")

retryable = False
reason = ""
if is_error and api_status in {"429", "529"}:
    retryable = True
    reason = f"api_error_status={api_status}"
elif assistant_error == "rate_limit":
    retryable = True
    reason = "assistant_error=rate_limit"
elif re.search(r"\b(?:429|rate[- ]?limit|usage limit|too many concurrent requests|you(?:'ve| have) hit your session limit)\b", stderr, re.I):
    retryable = True
    reason = "stderr-rate-limit"

no_progress = tool_uses == 0 and input_tokens == 0 and output_tokens == 0 and cost == 0
if not no_progress:
    retryable = False
    reason = ""

print(sep.join([
    "1" if retryable else "0",
    reason,
    str(tool_uses),
    str(input_tokens),
    str(output_tokens),
    str(cost),
    result.replace(sep, " ").replace("\n", " ").replace("\r", " ").strip()[:240],
]))
PY
    )
    IFS=$'\x1f' read -r SHOULD_RETRY RETRY_REASON _ _ _ _ RETRY_RESULT <<< "$RETRY_META"
    if [[ "$SHOULD_RETRY" == "1" ]]; then
      mark_auth_profile_cooldown "$AUTH_ATTEMPT_PROFILE" "rate_limit" "${RETRY_RESULT:-$RETRY_REASON}"
      echo "[foreman] Auth profile '$AUTH_ATTEMPT_PROFILE' hit retryable quota signal ($RETRY_REASON); cooling it down for ${AUTH_PROFILE_COOLDOWN_SECONDS}s and trying next profile." >&2
      continue
    fi
  fi

  break
done

# --- Parse normalized metadata ---
# Read all single-line scalar fields in ONE python3 invocation, joined by the
# ASCII Unit Separator (0x1f). A non-whitespace delimiter is required so empty
# fields (e.g. a blank session_id) are preserved by `read` rather than collapsed.
# RESULT_TEXT is parsed in its own call below because it can span multiple lines.
META_SCALARS=$(python3 -c "
import json
sep = chr(31)
try:
    d = json.load(open('$TMPMETA'))
except Exception:
    d = {}
fields = [
    '1' if d.get('found_result') else '0',
    str(d.get('total_cost_usd', 0)),
    str(d.get('num_turns', 0)),
    str(d.get('stop_reason', 'unknown') or 'unknown'),
    str(d.get('session_id', '') or ''),
    str(len(d.get('permission_denials', []) or [])),
]
print(sep.join(fields))
" 2>/dev/null || printf '0\x1f0\x1f0\x1funknown\x1f\x1f0')

IFS=$'\x1f' read -r FOUND_RESULT COST NUM_TURNS STOP_REASON SESSION_ID PERM_DENIALS <<< "$META_SCALARS"
# Defensive defaults in case of a truncated/short read.
FOUND_RESULT="${FOUND_RESULT:-0}"
COST="${COST:-0}"
NUM_TURNS="${NUM_TURNS:-0}"
STOP_REASON="${STOP_REASON:-unknown}"
PERM_DENIALS="${PERM_DENIALS:-0}"

RESULT_TEXT=$(python3 -c "
import json
try:
    d = json.load(open('$TMPMETA'))
    print(d.get('result', ''))
except:
    print('')
" 2>/dev/null || echo "")

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
# Serialize the cost-log read-modify-write across concurrent dispatches with an
# advisory lock so simultaneous writes can't lose each other's update. flock is
# best-effort: if it isn't installed the write still proceeds without the guard.
(
flock -w 10 9 2>/dev/null || true
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
# Atomic write: dump to a temp file then os.replace so any concurrent reader
# always sees a complete cost log (old or new), never a half-written file.
tmp_path = log_path + ".tmp"
json.dump(entries, open(tmp_path, "w"), indent=2)
os.replace(tmp_path, log_path)
'
) 9>"$COST_LOG.lock" || echo "[foreman] WARNING: cost-log write failed (continuing)." >&2

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
  OUT_ARTIFACT="$ARTIFACT_DIR/incomplete-${TS}-$$-${PROFILE}-${ARTIFACT_REASON}.jsonl"
  ERR_ARTIFACT="$ARTIFACT_DIR/incomplete-${TS}-$$-${PROFILE}-${ARTIFACT_REASON}.stderr"
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

# --- Determine final exit code ---
# Trust the Claude CLI's own exit code as the primary failure signal. A non-zero
# exit can accompany a `result` event whose text merely *contains* an error
# (e.g. an invalid/unavailable model: the CLI exits 1 but still emits a
# subtype=success result holding the error message). So "a result event exists"
# is NOT a reliable success signal, and we must never flip a CLI failure to 0.
# We only override in the SAFE direction: when the CLI reports success (exit 0)
# but produced no usable result event, surface that as a failure so callers
# don't mistake a silent no-result run for success.
if [[ "$EXIT_CODE" -ne 0 ]]; then
  FINAL_EXIT="$EXIT_CODE"
elif [[ "$FOUND_RESULT" != "1" ]]; then
  FINAL_EXIT=1
else
  FINAL_EXIT=0
fi

if [[ "$FINAL_EXIT" != "$EXIT_CODE" ]]; then
  echo "[foreman] Note: claude CLI exit code was $EXIT_CODE; reporting $FINAL_EXIT based on result presence." >&2
fi

# --- Output result ---
echo ""
echo "$RESULT_TEXT"

exit "$FINAL_EXIT"
