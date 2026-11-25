#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/scripts/lib/common.sh"
usage() { echo "用法: report.sh [--date YYYY-MM-DD]" >&2; }
DATE="$(date '+%F')"
while [ $# -gt 0 ]; do
  case "$1" in
    --date) [ $# -ge 2 ] || { usage; exit 64; }; DATE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { usage; exit 64; }
load_env
[ -f "$TARGETS_FILE" ] || {
  echo "[FAIL] targets.yaml not found: $TARGETS_FILE" >&2; exit 64; }
ROWS="$(target_rows "$TARGETS_FILE")"
validate_targets "$ROWS" || exit 64
NAMES="$(target_names "$TARGETS_FILE")"
FILE="$DATA_DIR/$DATE.jsonl"
[ -f "$FILE" ] || { echo "[FAIL] data file not found: $FILE" >&2; exit 66; }
awk -v names="$NAMES" '
function sval(line, key,  p) {
  p = "\"" key "\":\"";
  if (match(line, p "[^\"]*\""))
    return substr(line, RSTART + length(p), RLENGTH - length(p) - 1);
  return "";
}
function nval(line, key,  p) {
  p = "\"" key "\":";
  if (match(line, p "[0-9]+"))
    return substr(line, RSTART + length(p), RLENGTH - length(p));
  return "";
}
{
  ev = sval($0, "event"); tg = sval($0, "target");
  if (ev == "sample") {
    c[tg]++;
    if (sval($0, "status") == "ok") ok[tg]++;
    lat = nval($0, "latency_ms");
    if (lat != "") { n[tg]++; L[tg SUBSEP n[tg]] = lat }
  } else if (ev == "alert") {
    al[tg]++;
  } else if (ev == "recovered") {
    rec[tg]++;
  }
}
END {
  nt = split(names, nm, ",");
  printf "%-16s %8s %6s %8s %8s %7s %9s\n", "TARGET", "SAMPLES", "OK", "AVAIL%", "P95ms", "ALERTS", "RECOVERED";
  for (i = 1; i <= nt; i++) {
    t = nm[i];
    m = n[t] + 0;
    for (j = 1; j <= m; j++) v[j] = L[t SUBSEP j] + 0;
    for (j = 2; j <= m; j++) {
      x = v[j]; k = j - 1;
      while (k >= 1 && v[k] > x) { v[k + 1] = v[k]; k-- }
      v[k + 1] = x;
    }
    if (m > 0) {
      idx = int((m * 95 + 99) / 100);
      if (idx < 1) idx = 1;
      p95 = v[idx];
    } else {
      p95 = "-";
    }
    if (c[t] > 0) avail = ok[t] * 100 / c[t]; else avail = "-";
    printf "%-16s %8d %6d %8s %8s %7d %9d\n", t, c[t] + 0, ok[t] + 0, \
      (avail == "-" ? "-" : sprintf("%.1f", avail)), p95, al[t] + 0, rec[t] + 0;
  }
}
' "$FILE"
