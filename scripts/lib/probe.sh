#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"
elapsed_ms() { awk -v s="$1" -v e="$2" 'BEGIN{ printf "%.0f", (e-s)/1000000 }'; }
probe_http() { # $1 url $2 expect $3 timeout
  local target="$1" expect="$2" timeout="$3" start end resp rc=0 code sec ms cap
  cap="${CURL_MAX_TIME:-$timeout}"
  [ "$cap" -gt "$timeout" ] && cap="$timeout"
  start="$(date '+%s%N')"
  resp="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time "$cap" "$target" 2>/dev/null)" || rc=$?
  end="$(date '+%s%N')"
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 28 ]; then
      printf 'fail||timeout|curl timeout after %ss\n' "$cap"
    else
      printf 'fail||curl-%s|curl exit %s\n' "$rc" "$rc"
    fi
    return 0
  fi
  code="${resp%% *}"; sec="${resp##* }"; ms="$(elapsed_ms "$start" "$end")"
  if [ "$code" = "$expect" ]; then
    printf 'ok|%s|%s|HTTP %s %.3fs\n' "$ms" "$code" "$code" "$sec"
  else
    printf 'fail|%s|%s|expect %s, got %s\n' "$ms" "$code" "$expect" "$code"
  fi
}
probe_tcp() { # $1 host:port $2 expect $3 timeout
  local target="$1" timeout="$3" host port start end ms rc
  host="${target%:*}"; port="${target##*:}"
  start="$(date '+%s%N')"
  if timeout "$timeout" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
    printf 'ok|%s|open|tcp %s open\n' "$ms" "$target"
  else
    rc=$?; end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
    if [ "$rc" -eq 124 ]; then
      printf 'fail|%s|timeout|tcp %s timeout after %ss\n' "$ms" "$target" "$timeout"
    else
      printf 'fail|%s|closed|tcp %s closed (rc=%s)\n' "$ms" "$target" "$rc"
    fi
  fi
  return 0
}
probe_proc() { # $1 target $2 timeout
  local target="$1" start end ms
  start="$(date '+%s%N')"
  if [[ "$target" == *.service ]]; then
    if systemctl is-active --quiet "$target"; then
      end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
      printf 'ok|%s|active|systemd %s active\n' "$ms" "$target"
    else
      end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
      printf 'fail|%s|inactive|systemd %s not active\n' "$ms" "$target"
    fi
  elif pgrep -f -- "$target" >/dev/null 2>&1; then
    end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
    printf 'ok|%s|found|process matched %s\n' "$ms" "$target"
  else
    end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
    printf 'fail|%s|notfound|no process matched %s\n' "$ms" "$target"
  fi
}
probe_disk() { # $1 path $2 warn $3 crit
  local target="$1" warn="$2" crit="$3" start end ms usage status
  start="$(date '+%s%N')"
  usage="$(df -P "$target" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')"
  end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
  if [ -z "$usage" ]; then
    printf 'fail|%s|df-error|df failed for %s\n' "$ms" "$target"
    return 0
  fi
  status="$(metric_decision "$usage" "$warn" "$crit")"
  printf '%s|%s|%s|df %s used=%s%% warn=%s crit=%s\n' \
    "$status" "$ms" "$usage" "$target" "$usage" "$warn" "$crit"
}
probe_mem() { # $1 target $2 warn $3 crit；用 MemTotal/MemAvailable 算使用率
  local warn="$2" crit="$3" start end ms total avail usage status
  start="$(date '+%s%N')"
  read -r total avail < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
  end="$(date '+%s%N')"; ms="$(elapsed_ms "$start" "$end")"
  if [ -z "${total:-}" ] || [ -z "${avail:-}" ] || [ "$total" -le 0 ]; then
    printf 'fail|%s|meminfo|MemTotal/MemAvailable missing\n' "$ms"
    return 0
  fi
  usage="$(awk -v t="$total" -v a="$avail" 'BEGIN{ printf "%.0f", (t-a)*100/t }')"
  status="$(metric_decision "$usage" "$warn" "$crit")"
  printf '%s|%s|%s|mem used=%s%% available=%s/%s kB warn=%s crit=%s\n' \
    "$status" "$ms" "$usage" "$usage" "$avail" "$total" "$warn" "$crit"
}
probe_target() { # $1 type $2 target $3 expect $4 timeout $5 warn $6 crit
  case "$1" in
    http) probe_http "$2" "$3" "$4" ;;
    tcp) probe_tcp "$2" "$3" "$4" ;;
    proc) probe_proc "$2" "$4" ;;
    disk) probe_disk "$2" "$5" "$6" ;;
    mem) probe_mem "$2" "$5" "$6" ;;
    *) printf 'fail||type|unknown probe type: %s\n' "$1"; return 64 ;;
  esac
}
