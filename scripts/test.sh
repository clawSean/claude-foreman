#!/usr/bin/env bash
# Offline regression tests for claude-foreman.
# No live Claude/API calls: the claude binary is replaced with a fake stream.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMPDIR=""

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

assert_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_executable() {
  local path="$1"
  local label="$2"
  if [[ -x "$path" ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    fail "$label"
  else
    pass "$label"
  fi
}

run_expect_success() {
  local label="$1"
  shift
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

run_expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$label"
  else
    pass "$label"
  fi
}

make_fake_claude() {
  local fake_dir="$1"
  cat > "$fake_dir/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_CLAUDE_LOG:?missing FAKE_CLAUDE_LOG}"
: "${FAKE_CLAUDE_MODE:=success}"

{
  printf 'ARGS\n'
  printf '%s\n' "$@"
  printf 'TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
} >> "$FAKE_CLAUDE_LOG"

case "$FAKE_CLAUDE_MODE" in
  success)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-success-session","model":"opus"}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
{"type":"result","subtype":"success","result":"FOREMAN_STREAM_OK","total_cost_usd":0.0123,"num_turns":1,"session_id":"fake-success-session"}
JSON
    ;;
  max_turns)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-max-session","model":"opus"}
{"type":"result","subtype":"error_max_turns","result":"FOREMAN_PARTIAL","total_cost_usd":0.5,"num_turns":15,"session_id":"fake-max-session"}
JSON
    ;;
  no_result)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-no-result-session","model":"opus"}
JSON
    exit 42
    ;;
  permission_denial)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-denial-session","model":"opus"}
{"type":"result","subtype":"success","result":"FOREMAN_DENIAL_OK","total_cost_usd":0.25,"num_turns":2,"session_id":"fake-denial-session","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"cat /root/.secrets/example"}}]}
JSON
    ;;
  redaction)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-redaction-session","model":"opus"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://example.com/path?token=SECRET_TOKEN#frag"}}],"stop_reason":"tool_use"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
{"type":"result","subtype":"success","result":"FOREMAN_REDACTION_OK","total_cost_usd":0,"num_turns":2,"session_id":"fake-redaction-session"}
JSON
    ;;
  rate_limit_personal)
    if [[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" == "personal-token" ]]; then
      cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 2:20am (UTC)"}],"stop_reason":"end_turn"},"error":"rate_limit"}
{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your session limit · resets 2:20am (UTC)","total_cost_usd":0,"num_turns":1,"session_id":"fake-rate-limit-session","usage":{"input_tokens":0,"output_tokens":0}}
JSON
      exit 1
    fi
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-fallback-session","model":"opus"}
{"type":"assistant","message":{"content":[{"type":"text","text":"fallback ok"}],"stop_reason":"end_turn"}}
{"type":"result","subtype":"success","result":"FOREMAN_FALLBACK_OK","total_cost_usd":0.034,"num_turns":1,"session_id":"fake-fallback-session","usage":{"input_tokens":10,"output_tokens":3}}
JSON
    ;;
  *)
    echo "unknown fake mode: $FAKE_CLAUDE_MODE" >&2
    exit 99
    ;;
esac
SH
  chmod +x "$fake_dir/claude"
}

run_dispatch() {
  local mode="$1"
  local target="$2"
  local prompt="$3"
  shift 3

  FAKE_CLAUDE_MODE="$mode" \
  FAKE_CLAUDE_LOG="$TMPDIR/claude-$mode.log" \
  PATH="$TMPDIR/fake-bin:$PATH" \
    "$SKILL_DIR/scripts/dispatch.sh" plan "$target" "$prompt" "$@" 2>&1
}

echo "=== claude-foreman offline tests ==="
echo ""

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/fake-bin" "$TMPDIR/target"
make_fake_claude "$TMPDIR/fake-bin"

echo "[1] Structure"
assert_file "$SKILL_DIR/SKILL.md" "SKILL.md exists"
assert_file "$SKILL_DIR/README.md" "README.md exists"
assert_file "$SKILL_DIR/scripts/dispatch.sh" "dispatch.sh exists"
assert_executable "$SKILL_DIR/scripts/dispatch.sh" "dispatch.sh is executable"
assert_file "$SKILL_DIR/scripts/smoke-claude-profile.sh" "smoke-claude-profile.sh exists"
assert_executable "$SKILL_DIR/scripts/smoke-claude-profile.sh" "smoke-claude-profile.sh is executable"
assert_file "$SKILL_DIR/scripts/smoke-openclaw-model.sh" "smoke-openclaw-model.sh exists"
assert_executable "$SKILL_DIR/scripts/smoke-openclaw-model.sh" "smoke-openclaw-model.sh is executable"
for profile in plan implement review wide-open; do
  assert_file "$SKILL_DIR/profiles/${profile}.md" "profiles/${profile}.md exists"
done

echo ""
echo "[2] Syntax and lint"
run_expect_success "dispatch.sh passes bash -n" bash -n "$SKILL_DIR/scripts/dispatch.sh"
run_expect_success "smoke-claude-profile.sh passes bash -n" bash -n "$SKILL_DIR/scripts/smoke-claude-profile.sh"
run_expect_success "smoke-openclaw-model.sh passes bash -n" bash -n "$SKILL_DIR/scripts/smoke-openclaw-model.sh"
if command -v shellcheck >/dev/null 2>&1; then
  run_expect_success "dispatch.sh passes shellcheck" shellcheck "$SKILL_DIR/scripts/dispatch.sh"
  run_expect_success "test.sh passes shellcheck" shellcheck "$SKILL_DIR/scripts/test.sh"
  run_expect_success "smoke-claude-profile.sh passes shellcheck" shellcheck "$SKILL_DIR/scripts/smoke-claude-profile.sh"
  run_expect_success "smoke-openclaw-model.sh passes shellcheck" shellcheck "$SKILL_DIR/scripts/smoke-openclaw-model.sh"
else
  echo "  SKIP: shellcheck not installed"
fi

echo ""
echo "[3] Argument validation"
run_expect_failure "dispatch.sh with no args exits non-zero" "$SKILL_DIR/scripts/dispatch.sh"
run_expect_failure "dispatch.sh with 1 arg exits non-zero" "$SKILL_DIR/scripts/dispatch.sh" plan
run_expect_failure "dispatch.sh with 2 args exits non-zero" "$SKILL_DIR/scripts/dispatch.sh" plan "$TMPDIR/target"
run_expect_failure "dispatch.sh rejects unknown profile" "$SKILL_DIR/scripts/dispatch.sh" bogus-profile "$TMPDIR/target" "test"
run_expect_failure "dispatch.sh rejects nonexistent target dir" "$SKILL_DIR/scripts/dispatch.sh" plan "$TMPDIR/nope" "test"
run_expect_failure "dispatch.sh rejects unknown flags" "$SKILL_DIR/scripts/dispatch.sh" plan "$TMPDIR/target" "test" --bogus-flag

echo ""
echo "[4] Root safety"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  set +e
  "$SKILL_DIR/scripts/dispatch.sh" claws-out "$TMPDIR/target" "test" >/dev/null 2>&1
  exit_code=$?
  set -e
  if [[ "$exit_code" -eq 3 ]]; then
    pass "claws-out blocked as root with exit code 3"
  else
    fail "claws-out root block exit code is $exit_code, expected 3"
  fi

  unsafe_stderr=$("$SKILL_DIR/scripts/dispatch.sh" unsafe "$TMPDIR/target" "test" 2>&1 >/dev/null || true)
  assert_contains "$unsafe_stderr" "deprecated" "'unsafe' alias prints deprecation notice"
else
  echo "  SKIP: not running as root"
fi

echo ""
echo "[5] stream-json success path"
success_out=$(run_dispatch success "$TMPDIR/target" "fake prompt" --max-turns 3)
assert_contains "$success_out" "FOREMAN_STREAM_OK" "prints final result text"
assert_contains "$success_out" "[foreman] Stop reason: end_turn" "normalizes success stop reason"
assert_contains "$success_out" "[foreman] Stream:" "prints stream artifact path"
assert_contains "$(cat "$TMPDIR/claude-success.log")" "--output-format" "passes --output-format flag"
assert_contains "$(cat "$TMPDIR/claude-success.log")" "stream-json" "uses stream-json output"
assert_contains "$(cat "$TMPDIR/claude-success.log")" "--verbose" "passes --verbose"
assert_contains "$(cat "$TMPDIR/claude-success.log")" "FINAL-OUTPUT REQUIREMENT" "appends final-output guardrail"
assert_contains "$(cat "$TMPDIR/claude-success.log")" "Bash(git:*),Bash(ls:*)" "uses separate Bash allowlist entries"

echo ""
echo "[6] Incomplete and diagnostic paths"
max_out=$(run_dispatch max_turns "$TMPDIR/target" "max prompt" --max-turns 15 || true)
assert_contains "$max_out" "[foreman] Stop reason: max_turns" "maps error_max_turns to max_turns"
assert_contains "$max_out" "Artifacts saved:" "saves max-turns artifact"
assert_contains "$max_out" "FOREMAN_PARTIAL" "prints partial result text"

set +e
no_result_out=$(run_dispatch no_result "$TMPDIR/target" "no result prompt" --max-turns 2)
no_result_exit=$?
set -e
if [[ "$no_result_exit" -eq 42 ]]; then
  pass "preserves claude exit code for no-result runs"
else
  fail "no-result exit code is $no_result_exit, expected 42"
fi
assert_contains "$no_result_out" "no result event" "reports missing result event"
assert_contains "$no_result_out" "Artifacts saved:" "saves no-result artifact"

denial_out=$(run_dispatch permission_denial "$TMPDIR/target" "denial prompt" --max-turns 3)
assert_contains "$denial_out" "Permission denials: 1" "prints permission-denial count"
assert_contains "$denial_out" "FOREMAN_DENIAL_OK" "prints result when permission denials exist"
assert_contains "$denial_out" "Artifacts saved:" "saves permission-denial artifact"

echo ""
echo "[7] Progress redaction"
redaction_out=$(run_dispatch redaction "$TMPDIR/target" "redaction prompt" --max-turns 3)
assert_contains "$redaction_out" "https://example.com/path [args stripped]" "strips URL query and fragment in progress output"
assert_not_contains "$redaction_out" "SECRET_TOKEN" "does not leak URL token in progress output"

echo ""
echo "[8] Env-backed Claude profiles"
cat > "$TMPDIR/profiles.json" <<'JSON'
{
  "active": "personal",
  "profiles": {
    "personal": {
      "label": "Fake Personal",
      "env_var": "FAKE_PERSONAL_TOKEN"
    },
    "work": {
      "label": "Fake Work",
      "env_var": "FAKE_WORK_TOKEN"
    }
  }
}
JSON

profile_out=$(
  FOREMAN_CLAUDE_PROFILES_FILE="$TMPDIR/profiles.json" \
  FAKE_PERSONAL_TOKEN="personal-token" \
  FAKE_WORK_TOKEN="work-token" \
  run_dispatch success "$TMPDIR/target" "profile prompt" --profile work --max-turns 3
)
assert_contains "$profile_out" "Auth lane: claude-cli (work; env \$FAKE_WORK_TOKEN)" "reports selected profile env var"
assert_contains "$(cat "$TMPDIR/claude-success.log")" "TOKEN=work-token" "exports requested profile token to Claude"

missing_profile_out=$(
  FOREMAN_CLAUDE_PROFILES_FILE="$TMPDIR/profiles.json" \
  FAKE_PERSONAL_TOKEN="personal-token" \
  FAKE_WORK_TOKEN="work-token" \
  run_dispatch success "$TMPDIR/target" "missing profile prompt" --profile nope --max-turns 3 || true
)
assert_contains "$missing_profile_out" "Unknown Claude profile: nope" "rejects unknown profile"

missing_token_out=$(
  FOREMAN_CLAUDE_PROFILES_FILE="$TMPDIR/profiles.json" \
  FAKE_PERSONAL_TOKEN="personal-token" \
  FAKE_WORK_TOKEN="" \
  run_dispatch success "$TMPDIR/target" "missing token prompt" --profile work --max-turns 3 || true
)
assert_contains "$missing_token_out" "Expected a token in \$FAKE_WORK_TOKEN" "rejects empty profile env var"

echo ""
echo "[9] Claude profile fallback"
cat > "$TMPDIR/fallback-profiles.json" <<'JSON'
{
  "active": "personal",
  "profiles": {
    "personal": {
      "label": "Fake Personal",
      "env_var": "FAKE_PERSONAL_TOKEN",
      "cooldown_until": 0
    },
    "work": {
      "label": "Fake Work",
      "env_var": "FAKE_WORK_TOKEN",
      "cooldown_until": 0
    }
  }
}
JSON

: > "$TMPDIR/claude-rate_limit_personal.log"
fallback_out=$(
  FOREMAN_CLAUDE_PROFILES_FILE="$TMPDIR/fallback-profiles.json" \
  FOREMAN_CLAUDE_PROFILE_COOLDOWN_SECONDS=600 \
  FAKE_PERSONAL_TOKEN="personal-token" \
  FAKE_WORK_TOKEN="work-token" \
  run_dispatch rate_limit_personal "$TMPDIR/target" "fallback prompt" --provider claude-cli --max-turns 3
)
assert_contains "$fallback_out" "Auth lane: claude-cli fallback (personal -> work)" "reports profile fallback order"
assert_contains "$fallback_out" "Auth attempt 1/2: personal" "prints first auth attempt"
assert_contains "$fallback_out" "Auth attempt 2/2: work" "prints second auth attempt"
assert_contains "$fallback_out" "retryable quota signal" "reports retryable quota fallback"
assert_contains "$fallback_out" "FOREMAN_FALLBACK_OK" "falls through to second profile result"
assert_contains "$(cat "$TMPDIR/claude-rate_limit_personal.log")" "TOKEN=personal-token" "tries active personal token first"
assert_contains "$(cat "$TMPDIR/claude-rate_limit_personal.log")" "TOKEN=work-token" "tries work token after personal quota"
cooldown_check=$(
  python3 - "$TMPDIR/fallback-profiles.json" <<'PY'
import json, sys, time
data = json.load(open(sys.argv[1]))
cooldown = int(data["profiles"]["personal"].get("cooldown_until") or 0)
print("cooldown-set" if cooldown > int(time.time()) else "cooldown-missing")
PY
)
assert_contains "$cooldown_check" "cooldown-set" "records cooldown on failed profile"

cat > "$TMPDIR/strict-profiles.json" <<'JSON'
{
  "active": "personal",
  "profiles": {
    "personal": {
      "label": "Fake Personal",
      "env_var": "FAKE_PERSONAL_TOKEN",
      "cooldown_until": 0
    },
    "work": {
      "label": "Fake Work",
      "env_var": "FAKE_WORK_TOKEN",
      "cooldown_until": 0
    }
  }
}
JSON

: > "$TMPDIR/claude-rate_limit_personal.log"
strict_out=$(
  FOREMAN_CLAUDE_PROFILES_FILE="$TMPDIR/strict-profiles.json" \
  FAKE_PERSONAL_TOKEN="personal-token" \
  FAKE_WORK_TOKEN="work-token" \
  run_dispatch rate_limit_personal "$TMPDIR/target" "strict prompt" --profile personal --max-turns 3 || true
)
assert_contains "$strict_out" "Auth lane: claude-cli (personal; env \$FAKE_PERSONAL_TOKEN)" "explicit profile remains strict"
assert_contains "$strict_out" "You've hit your session limit" "strict profile surfaces original quota result"
assert_not_contains "$(cat "$TMPDIR/claude-rate_limit_personal.log")" "TOKEN=work-token" "strict profile does not try fallback token"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
