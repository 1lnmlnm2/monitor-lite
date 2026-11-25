#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF_FILE="${MONITOR_CONF:-/opt/monitor-lite/monitor.env}"
TARGETS_FILE="${MONITOR_TARGETS:-$KIT_ROOT/checks/targets.yaml}"
load_env() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi
  : "${DATA_DIR:=/opt/monitor-lite/data}" "${LOG_DIR:=/opt/monitor-lite/logs}"
  : "${INTERVAL:=60}" "${FAIL_THRESHOLD:=3}" "${CURL_MAX_TIME:=3}"
  mkdir -p "$DATA_DIR" "$DATA_DIR/state" "$LOG_DIR"
  STATE_DIR="$DATA_DIR/state"
  DAILY_FILE="$DATA_DIR/$(date '+%F').jsonl"
  LOCK_FILE="$DATA_DIR/.monitor.lock"
  umask 027
}
now_epoch() { date '+%s'; }
now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
metric_decision() { # $1 值 $2 warn $3 crit → ok/warn/fail
  awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{ if (v >= c) print "fail"; else if (v >= w) print "warn"; else print "ok" }'
}
target_rows() { # 解析固定缩进的 targets.yaml，输出 name|type|target|expect|timeout|warn|crit
  awk '
    function trim(x) { sub(/^[[:space:]]+/,"",x); sub(/[[:space:]]+/,"",x); sub(/[[:space:]]*#.*$/,"",x); gsub(/^["\047]|["\047]$/,"",x); return x }
    function value(line) { sub(/^[^:]+:[[:space:]]*/,"",line); return trim(line) }
    function flush() { if (name != "") print name "|" type "|" target "|" expect "|" timeout "|" warn "|" crit }
    /^[[:space:]]*-[[:space:]]*name:/ { flush(); name=value($0); type=""; target=""; expect=""; timeout=""; warn=""; crit="" }
    /^[[:space:]]+type:/ { type=value($0) }
    /^[[:space:]]+target:/ { target=value($0) }
    /^[[:space:]]+expect:/ { expect=value($0) }
    /^[[:space:]]+timeout:/ { timeout=value($0) }
    /^[[:space:]]+warn:/ { warn=value($0) }
    /^[[:space:]]+crit:/ { crit=value($0) }
    END { flush() }
  ' "$1"
}
target_names() {
  target_rows "$1" | awk -F'|' '{ printf "%s%s", sep, $1; sep="," }'
}
validate_targets() { # $1 rows
  local rows="$1" line name type target expect timeout warn crit
  local -A seen=()
  [ -n "$rows" ] || { echo "[FAIL] targets.yaml 无有效目标" >&2; return 64; }
  while IFS='|' read -r name type target expect timeout warn crit; do
    [ -n "$name" ] || continue
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
      echo "[FAIL] 非法 target 名: $name" >&2; return 64; }
    [ -z "${seen[$name]:-}" ] || {
      echo "[FAIL] target 重复: $name" >&2; return 64; }
    seen[$name]=1
    case "$type" in
      http|tcp|proc|disk|mem) ;;
      *) echo "[FAIL] 非法 type: $type（target=$name）" >&2; return 64 ;;
    esac
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || {
      echo "[FAIL] timeout 必须是正整数: $name" >&2; return 64; }
    [ "$timeout" -le 60 ] || {
      echo "[FAIL] timeout 不能超过 60 秒: $name" >&2; return 64; }
    [[ "$warn" =~ ^[0-9]+$ && "$crit" =~ ^[0-9]+$ ]] || {
      echo "[FAIL] warn/crit 必须是整数: $name" >&2; return 64; }
    [ "$warn" -le 100 ] && [ "$crit" -le 100 ] || {
      echo "[FAIL] warn/crit 必须在 0..100: $name" >&2; return 64; }
    case "$type" in
      http)
        [[ "$target" =~ ^http://127\.0\.0\.1:[0-9]+/ ]] || {
          echo "[FAIL] http target 只允许 127.0.0.1 URL: $target" >&2; return 64; }
        [[ "$expect" =~ ^[1-5][0-9][0-9]$ ]] || {
          echo "[FAIL] http expect 必须是 HTTP 状态码: $name" >&2; return 64; }
        ;;
      tcp)
        [[ "$target" =~ ^127\.0\.0\.1:[0-9]+$ ]] || {
          echo "[FAIL] tcp target 只允许 127.0.0.1:port: $target" >&2; return 64; }
        [ "$expect" = "open" ] || {
          echo "[FAIL] tcp expect 必须是 open: $name" >&2; return 64; }
        ;;
      proc)
        [ "$expect" = "active" ] && [[ "$target" != *[[:space:]]* ]] || {
          echo "[FAIL] proc expect=active 且 target 不能含空白: $name" >&2; return 64; }
        ;;
      disk)
        [ "$expect" = "usage" ] && [[ "$target" == /* ]] || {
          echo "[FAIL] disk expect=usage 且 target 必须是绝对路径: $name" >&2; return 64; }
        [ "$warn" -gt 0 ] && [ "$warn" -lt "$crit" ] || {
          echo "[FAIL] disk 需要 0 < warn < crit: $name" >&2; return 64; }
        ;;
      mem)
        [ "$expect" = "usage" ] || {
          echo "[FAIL] mem expect 必须是 usage: $name" >&2; return 64; }
        [ "$warn" -gt 0 ] && [ "$warn" -lt "$crit" ] || {
          echo "[FAIL] mem 需要 0 < warn < crit: $name" >&2; return 64; }
        ;;
    esac
  done <<< "$rows"
}
lock_monitor() {
  exec 9>>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "skipped: another run in progress"
    exit 0
  fi
}
state_load() { # $1 target：状态在 state/<name>.state
  STATE_FAIL=0; STATE_ALERTED=0; STATE_FIRST=0; STATE_LAST=""
  local f="$STATE_DIR/$1.state"
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    . "$f"
  fi
}
state_save() { # $1 target
  local f="$STATE_DIR/$1.state" tmp
  tmp="$f.$$"
  printf 'STATE_FAIL=%s\nSTATE_ALERTED=%s\nSTATE_FIRST=%s\nSTATE_LAST=%s\n' \
    "$STATE_FAIL" "$STATE_ALERTED" "$STATE_FIRST" "$STATE_LAST" > "$tmp"
  mv "$tmp" "$f"
}
append_jsonl() { printf '%s\n' "$1" >> "$DAILY_FILE"; }
