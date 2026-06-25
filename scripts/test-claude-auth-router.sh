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
  FAKE_TOKEN="fake-token" \
  CLAUDE_PROFILES_FILE="$TMPDIR/profiles.json" \
  CLAUDE_AUTH_ACTIVE_FILE="$TMPDIR/active" \
  PATH="$TMPDIR/fake-bin:$PATH" \
    "$ROUTER" "$@"
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
cat > "$TMPDIR/profiles.json" <<'JSON'
{
  "active": "personal",
  "profiles": {
    "personal": {
      "label": "Fake Personal",
      "env_var": "FAKE_TOKEN"
    }
  }
}
JSON
printf 'personal\n' > "$TMPDIR/active"

set +e
rate_out=$(run_router stream_rate_limit -p "test" --output-format stream-json --verbose 2>&1)
rate_exit=$?
set -e
if [[ "$rate_exit" -eq 0 ]]; then
  pass "stream-json rate limit exits successfully with friendly result"
else
  fail "stream-json rate limit exit code was $rate_exit"
fi
assert_contains "$rate_out" "Claude hit a session limit before I could answer that." "friendly message is emitted"
assert_contains "$rate_out" '"router_friendly_rate_limit":true' "friendly result is marked"
assert_not_contains "$rate_out" "You've hit your session limit" "raw Claude limit text is suppressed"
assert_not_contains "$rate_out" '"is_error":true' "raw error result is suppressed"

success_out=$(run_router stream_success_mentions_rate_limit -p "test" --output-format stream-json --verbose 2>&1)
assert_contains "$success_out" "Here is rate limit documentation." "successful content mentioning rate limit passes through"
assert_not_contains "$success_out" "router_friendly_rate_limit" "successful content does not trigger friendly rewrite"

set +e
stderr_out=$(run_router stderr_rate_limit -p "test" --output-format stream-json --verbose 2>&1)
stderr_exit=$?
set -e
if [[ "$stderr_exit" -eq 0 ]]; then
  pass "stderr-only rate limit exits successfully with friendly result"
else
  fail "stderr-only rate limit exit code was $stderr_exit"
fi
assert_contains "$stderr_out" "Claude hit a session limit before I could answer that." "stderr-only rate limit becomes friendly message"

interactive_out=$(run_router interactive 2>&1)
assert_contains "$interactive_out" "INTERACTIVE_OK" "interactive/no-print path passes through"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
