#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../scripts/lib/common.sh"
. "$SCRIPT_DIR/../scripts/lib/probe.sh"
load_env
RC=0
check() { # $1 场景 $2 期望状态，其余为 probe_target 参数
  local label="$1" expected="$2" result status
  shift 2
  result="$(probe_target "$@" 2>/dev/null || true)"
  status="${result%%|*}"
  if [ "$status" = "$expected" ]; then
    printf '[OK] %-14s %s\n' "$label" "$result"
  else
    printf '[FAIL] %-12s expected=%s got=%s\n' "$label" "$expected" "$result"
    RC=1
  fi
}
check "http-200" ok http http://127.0.0.1:8090/health.txt 200 3 0 0
check "tcp-closed" fail tcp 127.0.0.1:65534 open 1 0 0
NPID=""
systemd-socket-activate -l 127.0.0.1:18081 --accept /bin/sleep 2 >/dev/null 2>&1 &
NPID=$!
sleep 0.2
check "slow-timeout" fail http http://127.0.0.1:18081/ 200 1 0 0
kill "$NPID" 2>/dev/null || true
wait "$NPID" 2>/dev/null || true
check "proc-missing" fail proc monitor-lite-selftest-no-such-proc active 1 0 0
exit "$RC"
