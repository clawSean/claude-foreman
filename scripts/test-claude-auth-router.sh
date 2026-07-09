#!/usr/bin/env bash
# Offline tests for Sean's live Claude auth router wrapper.
# No live Claude/API calls: PATH is pointed at a fake claude binary.

set -euo pipefail

ROUTER="${CLAUDE_AUTH_ROUTER_UNDER_TEST:-/root/scripts/claude-auth-router.sh}"
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

make_fake_claude() {
  local fake_dir="$1"
  cat > "$fake_dir/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${FAKE_CLAUDE_MODE:-success}" in
  stream_rate_limit)
    cat <<'JSON'
{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour"},"session_id":"fake-rate-limit"}
{"type":"assistant","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 2:20am (UTC)"}],"stop_reason":"stop_sequence"},"error":"rate_limit"}
{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your session limit · resets 2:20am (UTC)","total_cost_usd":0,"num_turns":1,"usage":{"input_tokens":0,"output_tokens":0}}
JSON
    exit 1
    ;;
  stream_success_mentions_rate_limit)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-success","model":"fake"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Here is rate limit documentation."}],"stop_reason":"end_turn"}}
{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"Here is rate limit documentation.","total_cost_usd":0.01,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1}}
JSON
    ;;
  stderr_rate_limit)
    echo "You've hit your session limit · resets soon" >&2
    exit 1
    ;;
  interactive)
    printf 'INTERACTIVE_OK\n'
    ;;
  *)
    printf 'OK\n'
    ;;
esac
SH
  chmod +x "$fake_dir/claude"
}

run_router() {
  local mode="$1"
  shift
  FAKE_CLAUDE_MODE="$mode" \
  FAKE_PERSONAL_TOKEN="fake-personal-token" \
  FAKE_WORK_TOKEN="fake-work-token" \
  CLAUDE_PROFILES_FILE="$TMPDIR/profiles.json" \
  PATH="$TMPDIR/fake-bin:$PATH" \
    "$ROUTER" "$@"
}

write_profiles() {
  local variant="${1:-two}"
  case "$variant" in
    two)
      cat > "$TMPDIR/profiles.json" <<'JSON'
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
      ;;
    one)
      cat > "$TMPDIR/profiles.json" <<'JSON'
{
  "active": "personal",
  "profiles": {
    "personal": {
      "label": "Fake Personal",
      "env_var": "FAKE_PERSONAL_TOKEN",
      "cooldown_until": 0
    }
  }
}
JSON
      ;;
    *)
      echo "Unknown profile fixture: $variant" >&2
      exit 1
      ;;
  esac
}

json_active() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("active") or "")' "$TMPDIR/profiles.json"
}

echo "=== claude-auth-router offline tests ==="

if [[ ! -x "$ROUTER" ]]; then
  echo "Router under test is not executable: $ROUTER" >&2
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/fake-bin"
make_fake_claude "$TMPDIR/fake-bin"
write_profiles two

set +e
rate_out=$(run_router stream_rate_limit -p "test" --output-format stream-json --verbose 2>&1)
rate_exit=$?
set -e
if [[ "$rate_exit" -eq 0 ]]; then
  pass "stream-json rate limit exits successfully with friendly result"
else
  fail "stream-json rate limit exit code was $rate_exit"
fi
assert_contains "$rate_out" "Claude hit a session limit 🧱" "friendly message is emitted with emoji"
assert_contains "$rate_out" "switched Claude from Fake Personal to Fake Work 🔁" "friendly message says profile was switched with emoji"
assert_contains "$rate_out" "Please send your last message again now ⚡" "friendly message asks for immediate retry with emoji"
assert_contains "$rate_out" '"router_friendly_rate_limit":true' "friendly result is marked"
assert_contains "$rate_out" '"router_profile_rotated":true' "friendly result marks profile rotation"
assert_contains "$rate_out" '"router_next_profile":"work"' "friendly result records next profile"
assert_not_contains "$rate_out" "You've hit your session limit" "raw Claude limit text is suppressed"
assert_not_contains "$rate_out" '"is_error":true' "raw error result is suppressed"
assert_contains "$(json_active)" "work" "JSON active profile switches to next usable profile"
if [[ -e "$TMPDIR/active" ]]; then
  fail "router must not create a standalone active file"
else
  pass "router does not create a standalone active file"
fi
cooldown_check=$(
  python3 - "$TMPDIR/profiles.json" <<'PY'
import json, sys, time
data = json.load(open(sys.argv[1]))
cooldown = int(data["profiles"]["personal"].get("cooldown_until") or 0)
print("cooldown-set" if cooldown > int(time.time()) else "cooldown-missing")
PY
)
assert_contains "$cooldown_check" "cooldown-set" "rate-limited profile is cooled down"

write_profiles two
success_out=$(run_router stream_success_mentions_rate_limit -p "test" --output-format stream-json --verbose 2>&1)
assert_contains "$success_out" "Here is rate limit documentation." "successful content mentioning rate limit passes through"
assert_not_contains "$success_out" "router_friendly_rate_limit" "successful content does not trigger friendly rewrite"

write_profiles one
set +e
stderr_out=$(run_router stderr_rate_limit -p "test" --output-format stream-json --verbose 2>&1)
stderr_exit=$?
set -e
if [[ "$stderr_exit" -eq 0 ]]; then
  pass "stderr-only rate limit exits successfully with friendly result"
else
  fail "stderr-only rate limit exit code was $stderr_exit"
fi
assert_contains "$stderr_out" "Claude hit a session limit 🧱" "stderr-only rate limit becomes friendly message with emoji"
assert_contains "$stderr_out" "Please try your last message again after the limit resets ⏳" "single-profile message avoids immediate retry with emoji"
assert_contains "$stderr_out" '"router_profile_rotated":false' "single-profile result marks no rotation"

write_profiles two
set +e
pinned_out=$(run_router stream_rate_limit --auth-profile personal -p "test" --output-format stream-json --verbose 2>&1)
pinned_exit=$?
set -e
if [[ "$pinned_exit" -eq 0 ]]; then
  pass "pinned profile rate limit exits successfully with friendly result"
else
  fail "pinned profile rate limit exit code was $pinned_exit"
fi
assert_contains "$pinned_out" "pinned Fake Personal profile 📌" "pinned-profile message includes pin emoji"
assert_contains "$pinned_out" "after the limit resets ⏳" "pinned-profile message avoids immediate retry with emoji"
assert_contains "$pinned_out" '"router_profile_rotated":false' "pinned-profile result marks no rotation"
assert_contains "$(json_active)" "personal" "pinned profile does not switch JSON active profile"

interactive_out=$(run_router interactive 2>&1)
assert_contains "$interactive_out" "INTERACTIVE_OK" "interactive/no-print path passes through"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
