#!/usr/bin/env bash
# monitor.sh —— monitor-lite 单次入口：--once [--target <名>]
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/scripts/lib/common.sh"
. "$SCRIPT_DIR/scripts/lib/probe.sh"
usage() { echo "用法: monitor.sh --once [--target <名>]" >&2; }
MODE=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once) MODE="once"; shift ;;
    --target) [ $# -ge 2 ] || { usage; exit 64; }; ONLY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done
[ "$MODE" = "once" ] || { usage; exit 64; }
load_env
[ -f "$TARGETS_FILE" ] || {
  echo "[FAIL] targets.yaml not found: $TARGETS_FILE" >&2; exit 64; }
ROWS="$(target_rows "$TARGETS_FILE")"
validate_targets "$ROWS" || exit 64
if [ -n "$ONLY" ]; then
  ROWS="$(printf '%s\n' "$ROWS" | awk -F'|' -v n="$ONLY" '$1 == n')"
  [ -n "$ROWS" ] || { echo "[FAIL] target not found: $ONLY" >&2; exit 64; }
fi
lock_monitor
TOTAL=0; OK=0; FAIL=0; WARN=0
while IFS='|' read -r NAME TYPE TARGET EXPECT TIMEOUT WARN_TH CRIT_TH; do
  [ -n "$NAME" ] || continue
  RESULT="$(probe_target "$TYPE" "$TARGET" "$EXPECT" "$TIMEOUT" "$WARN_TH" "$CRIT_TH")"
  IFS='|' read -r STATUS LATENCY CODE DETAIL <<< "$RESULT"
  TOTAL=$((TOTAL + 1))
  case "$STATUS" in
    ok) OK=$((OK + 1)) ;;
    warn) WARN=$((WARN + 1)) ;;
    *) FAIL=$((FAIL + 1)) ;;
  esac
  if [ -n "$LATENCY" ]; then LAT_JSON="$LATENCY"; else LAT_JSON="null"; fi
  TS="$(now_iso)"
  append_jsonl "{\"ts\":\"$(json_escape "$TS")\",\"event\":\"sample\",\"target\":\"$(json_escape "$NAME")\",\"type\":\"$(json_escape "$TYPE")\",\"status\":\"$(json_escape "$STATUS")\",\"latency_ms\":${LAT_JSON},\"code\":\"$(json_escape "$CODE")\",\"detail\":\"$(json_escape "$DETAIL")\"}"
  NOW="$(now_epoch)"
  state_load "$NAME"
  PREV_FAIL="$STATE_FAIL"
  if [ "$STATUS" = "fail" ]; then
    STATE_FAIL=$((STATE_FAIL + 1))
    [ "$STATE_FIRST" -eq 0 ] && STATE_FIRST="$NOW"
    if [ "$STATE_FAIL" -ge "$FAIL_THRESHOLD" ] && [ "$STATE_ALERTED" -eq 0 ]; then
      DUR=$((NOW - STATE_FIRST))
      append_jsonl "{\"ts\":\"$(json_escape "$TS")\",\"event\":\"alert\",\"target\":\"$(json_escape "$NAME")\",\"type\":\"$(json_escape "$TYPE")\",\"status\":\"fail\",\"latency_ms\":${LAT_JSON},\"code\":\"$(json_escape "$CODE")\",\"fail_count\":${STATE_FAIL},\"duration_s\":${DUR},\"detail\":\"连续失败达到 ${FAIL_THRESHOLD} 次\"}"
      STATE_ALERTED=1
      printf 'alert   %-12s fail_count=%s duration_s=%s\n' "$NAME" "$STATE_FAIL" "$DUR"
    fi
  elif [ "$STATE_FAIL" -gt 0 ]; then
    DUR=$((NOW - STATE_FIRST))
    append_jsonl "{\"ts\":\"$(json_escape "$TS")\",\"event\":\"recovered\",\"target\":\"$(json_escape "$NAME")\",\"type\":\"$(json_escape "$TYPE")\",\"status\":\"$(json_escape "$STATUS")\",\"latency_ms\":${LAT_JSON},\"code\":\"$(json_escape "$CODE")\",\"fail_count\":${PREV_FAIL},\"duration_s\":${DUR},\"detail\":\"recovered after ${DUR}s\"}"
    printf 'recovered %-12s duration_s=%s\n' "$NAME" "$DUR"
    STATE_FAIL=0; STATE_ALERTED=0; STATE_FIRST=0
  fi
  STATE_LAST="$STATUS"
  state_save "$NAME"
  printf 'sample %-12s status=%-4s latency_ms=%s code=%s\n' "$NAME" "$STATUS" "${LATENCY:--}" "$CODE"
done <<< "$ROWS"
if [ "$WARN" -gt 0 ]; then
  echo "[OK] ${TOTAL} 目标 / ${OK} ok / ${FAIL} fail / ${WARN} warn"
else
  echo "[OK] ${TOTAL} 目标 / ${OK} ok / ${FAIL} fail"
fi
