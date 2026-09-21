#!/usr/bin/env bash
# item08 harness — vibed bug-fix verification, red/green TDD.
#
# Usage: vibed/tests/run.sh [red|green|regression]
#   red         bug tests 1-4 only,      logs -> .tmp/t/red<N>.log   (pre-fix evidence)
#   green       bug tests 1-4 + regression, logs -> .tmp/t/green<N>.log
#   regression  regression suite only,   log  -> .tmp/t/regression.log
#
# All scratch lives under $ROOT/.tmp/t/ — never /tmp.
# MISTRAL_API_KEY is loaded from $ROOT/.env and never printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VDIR="$ROOT/vibed"
BIN="$VDIR/target/release/vibed"
CLI="$VDIR/target/release/vibed-cli"
SERVICE="$VDIR/vibed.service"
T="$ROOT/.tmp/t"
PHASE="${1:-green}"
FAILURES=0
TEST_FAILED=0

mkdir -p "$T"

fail() { echo "FAIL: $*"; TEST_FAILED=1; }
note() { echo "note: $*"; }

tmo() {
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$s" "$@"
  else
    perl -e 'alarm shift; exec @ARGV or die "exec failed"' "$s" "$@"
  fi
}

start_daemon() { # $1 scratch dir; daemon stderr -> $1/daemon.err; echoes pid
  local d="$1"
  : > "$d/daemon.err"
  nohup "$BIN" >> "$d/daemon.err" 2>&1 < /dev/null &
  echo $!
}

kill_daemon() {
  # vibe-acp runs as "python .../vibe-acp", so name matches like -x never see
  # it; the child is identified by being the direct child of the daemon pid.
  local dp="$1" child
  child="$(pgrep -P "$dp" 2>/dev/null || true)"
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; fi
  kill "$dp" 2>/dev/null || true
  sleep 0.2
  pkill -f 'vibe-ac[p]' 2>/dev/null || true
  wait "$dp" 2>/dev/null || true
}

wait_ready() {
  local i=0
  while [ "$i" -lt 120 ]; do
    if tmo 5 "$CLI" status 2>/dev/null | grep -q '"up":true'; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  fail "daemon did not become ready in 60s"
  return 1
}

test_bug1() {
  local d="$T/b1" old="00000000-0000-0000-0000-000000000000"
  rm -rf "$d"; mkdir -p "$d/state"
  echo "$old" > "$d/state/session_id"
  export VIBED_SOCK="$d/vibed.sock" VIBED_STATE="$d/state/session_id" \
         VIBED_LOCK="$d/vibed.lock" VIBED_WORKDIR="$d"
  note "seeded $VIBED_STATE with $old"
  start_daemon "$d"
  local dp=$! rc=0 i=0
  while [ "$i" -lt 60 ]; do
    kill -0 "$dp" 2>/dev/null || break
    sleep 0.5
    i=$((i + 1))
  done
  if kill -0 "$dp" 2>/dev/null; then
    fail "daemon still alive after 30s — did not exit 3 (pre-fix: silently rebinds a fresh session)"
    kill "$dp" 2>/dev/null || true
    wait "$dp" 2>/dev/null || true
  else
    wait "$dp" 2>/dev/null || rc=$?
  fi
  note "daemon exit code: $rc"
  if [ "$rc" -ne 3 ]; then fail "expected exit code 3, got $rc"; fi
  if ! grep -q "PIN_LOST" "$d/daemon.err"; then
    fail "stderr missing literal PIN_LOST"
  fi
  note "daemon stderr:"
  sed 's/^/    | /' "$d/daemon.err"
  local bak="$VIBED_STATE.$old.bak"
  if [ ! -f "$bak" ]; then
    fail "backup file $bak missing"
  elif ! grep -q "$old" "$bak"; then
    fail "backup file does not contain the old id"
  fi
  local now
  now="$(tr -d '[:space:]' < "$VIBED_STATE" 2>/dev/null || true)"
  if [ "$now" != "$old" ]; then
    fail "state file changed: expected $old, got '${now:-<empty>}'"
  fi
  note "state dir listing:"
  ls -la "$d/state" | sed 's/^/    | /'
}

test_bug2() {
  local d="$T/b2"
  rm -rf "$d"; mkdir -p "$d"
  export VIBED_SOCK="$d/vibed.sock" VIBED_STATE="$d/state/session_id" \
         VIBED_LOCK="$d/vibed.lock" VIBED_WORKDIR="$d"
  start_daemon "$d"
  local dp=$!
  if ! wait_ready; then kill_daemon "$dp"; return 1; fi
  note "daemon ready; launching long push detached"
  local t0
  t0="$(date +%s)"
  setsid "$CLI" push "Count slowly from 1 to 60, one number per line." \
    > "$d/push.out" 2>&1 < /dev/null &
  sleep 0.3
  local i=0 seen=0 reply="" rc=0
  while [ "$i" -lt 60 ]; do
    rc=0
    reply="$(tmo 3 "$CLI" status 2>&1)" || rc=$?
    note "status poll $i (rc=$rc): $reply"
    if printf '%s' "$reply" | grep -q '"busy":true'; then
      seen=1
      break
    fi
    sleep 0.3
    i=$((i + 1))
  done
  local t1
  t1="$(date +%s)"
  note "elapsed $((t1 - t0))s; push stdout: $(cat "$d/push.out")"
  if [ "$seen" -ne 1 ]; then
    fail "status never reported \"busy\":true while a push was in flight (blocked behind the Acp mutex)"
  fi
  kill_daemon "$dp"
  pkill -x vibed-cli 2>/dev/null || true
}

test_bug3() {
  note "parsing $SERVICE"
  if ! grep -qE '^RestartSec=' "$SERVICE"; then
    fail "RestartSec= absent from unit (flock refusal + Restart=always = fast spin)"
    return 0
  fi
  local v
  v="$(grep -E '^RestartSec=' "$SERVICE" | head -1 | sed -E 's/^RestartSec=([0-9]+).*/\1/')"
  note "RestartSec=$v"
  if [ -z "$v" ] || [ "$v" -lt 3 ]; then
    fail "RestartSec must be present and >= 3, got '$v'"
  fi
}

test_bug4() {
  note "parsing $SERVICE"
  local sock lock
  sock="$(grep -E '^Environment=VIBED_SOCK=' "$SERVICE" | sed -E 's/^Environment=VIBED_SOCK=([^ ]*).*/\1/')"
  lock="$(grep -E '^Environment=VIBED_LOCK=' "$SERVICE" | sed -E 's/^Environment=VIBED_LOCK=([^ ]*).*/\1/')"
  note "VIBED_SOCK=$sock"
  note "VIBED_LOCK=$lock"
  case "$sock" in
    /run/vibed/*) ;;
    *) fail "VIBED_SOCK must start with /run/vibed/, got '${sock:-<unset>}'" ;;
  esac
  case "$lock" in
    /run/vibed/*) ;;
    *) fail "VIBED_LOCK must start with /run/vibed/, got '${lock:-<unset>}'" ;;
  esac
}

test_regression() {
  local d="$T/reg"
  rm -rf "$d"; mkdir -p "$d"
  export VIBED_SOCK="$d/vibed.sock" VIBED_STATE="$d/state/session_id" \
         VIBED_LOCK="$d/vibed.lock" VIBED_WORKDIR="$d"

  note "boot 1: clean -> session/new"
  start_daemon "$d"
  local dp=$! s1 s2
  if ! wait_ready; then kill_daemon "$dp"; return 1; fi
  if ! grep -q "session/new ok" "$d/daemon.err"; then
    fail "boot 1: 'session/new ok' not found in daemon log"
  fi
  s1="$(tmo 5 "$CLI" status | sed -E 's/.*"session":"([^"]*)".*/\1/')"
  note "session id after boot 1: $s1"
  if [ -z "$s1" ]; then fail "no session id after boot 1"; fi
  # Stock vibe-acp persists a session only once it has a turn; send one so
  # the restart below exercises session/load the way production does.
  local rc1=0 out1
  out1="$(tmo 90 "$CLI" push "Reply with exactly: ok" 2>&1)" || rc1=$?
  note "boot 1 push: $out1 (rc=$rc1)"
  if [ "$rc1" -ne 0 ]; then fail "boot 1 push failed (rc=$rc1)"; fi
  kill_daemon "$dp"

  note "boot 2: restart -> session/load, same id"
  start_daemon "$d"
  dp=$!
  if ! wait_ready; then kill_daemon "$dp"; return 1; fi
  if ! grep -q "session/load ok" "$d/daemon.err"; then
    fail "boot 2: 'session/load ok' not found in daemon log"
  fi
  if grep -q "session/new ok" "$d/daemon.err"; then
    fail "boot 2 fell back to session/new"
  fi
  s2="$(tmo 5 "$CLI" status | sed -E 's/.*"session":"([^"]*)".*/\1/')"
  note "session id after boot 2: $s2"
  if [ "$s1" != "$s2" ]; then
    fail "session id changed across restart: $s1 -> $s2"
  fi

  note "kill -9 vibe-acp child -> respawn, session/load, push end_turn"
  local child
  child="$(pgrep -P "$dp" 2>/dev/null || true)"
  if [ -z "$child" ]; then
    fail "could not find vibe-acp child of vibed pid $dp"
    kill_daemon "$dp"
    return 1
  fi
  note "child pid: $child"
  kill -9 "$child"
  local i=0
  while [ "$i" -lt 90 ]; do
    if [ "$(grep -c 'session ready' "$d/daemon.err")" -ge 2 ]; then break; fi
    sleep 1
    i=$((i + 1))
  done
  if [ "$(grep -c 'session ready' "$d/daemon.err")" -lt 2 ]; then
    fail "child did not respawn within 90s"
    kill_daemon "$dp"
    return 1
  fi
  if ! wait_ready; then kill_daemon "$dp"; return 1; fi
  if ! grep -q "session/load ok" "$d/daemon.err"; then
    fail "after respawn: 'session/load ok' not found in daemon log"
  fi
  local rc=0 out
  out="$(tmo 90 "$CLI" push "Reply with exactly: ok" 2>&1)" || rc=$?
  note "push reply: $out (rc=$rc)"
  if [ "$rc" -ne 0 ]; then
    fail "push after respawn failed (rc=$rc)"
  fi
  if ! printf '%s' "$out" | grep -q '"stopReason":"end_turn"'; then
    fail "push reply missing stopReason end_turn: $out"
  fi
  kill_daemon "$dp"
}

run_case() {
  local name="$1" log="$2"
  TEST_FAILED=0
  echo "== $name =="
  "$name" > "$log" 2>&1 || true
  if [ "$TEST_FAILED" -eq 0 ]; then
    echo "PASS $name (log: $log)"
  else
    echo "FAIL $name (log: $log)"
    FAILURES=$((FAILURES + 1))
  fi
  sed 's/^/    /' "$log"
}

cleanup() {
  pkill -x vibed 2>/dev/null || true
  pkill -f 'vibe-ac[p]' 2>/dev/null || true
  pkill -x vibed-cli 2>/dev/null || true
}
trap cleanup EXIT

command -v "$BIN" >/dev/null 2>&1 || {
  (cd "$VDIR" && cargo build --release --quiet) || exit 1
}
command -v vibe-acp >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
set -a
. "$ROOT/.env"
set +a

case "$PHASE" in
  red)
    run_case test_bug1 "$T/red1.log"
    run_case test_bug2 "$T/red2.log"
    run_case test_bug3 "$T/red3.log"
    run_case test_bug4 "$T/red4.log"
    ;;
  green)
    run_case test_bug1 "$T/green1.log"
    run_case test_bug2 "$T/green2.log"
    run_case test_bug3 "$T/green3.log"
    run_case test_bug4 "$T/green4.log"
    run_case test_regression "$T/green-regression.log"
    ;;
  regression)
    run_case test_regression "$T/regression.log"
    ;;
  *)
    echo "usage: $0 [red|green|regression]" >&2
    exit 2
    ;;
esac

echo
echo "pgrep-clean check:"
# vibe-acp runs as "python .../vibe-acp"; the [p] keeps the checker itself
# (and its parent shell) out of the match.
if pgrep -f 'vibe-ac[p]' >/dev/null 2>&1; then
  echo "vibe-acp still running: $(pgrep -f 'vibe-ac[p]' | tr '\n' ' ')"
  FAILURES=$((FAILURES + 1))
else
  echo "no vibe-acp"
fi
if pgrep -x vibed >/dev/null 2>&1; then
  echo "vibed still running: $(pgrep -x vibed | tr '\n' ' ')"
  FAILURES=$((FAILURES + 1))
else
  echo "no vibed"
fi
if pgrep -x vibed-cli >/dev/null 2>&1; then
  echo "vibed-cli still running: $(pgrep -x vibed-cli | tr '\n' ' ')"
  FAILURES=$((FAILURES + 1))
else
  echo "no vibed-cli"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "RESULT: $FAILURES test(s) FAILED"
  exit 1
fi
echo "RESULT: all tests PASSED"
