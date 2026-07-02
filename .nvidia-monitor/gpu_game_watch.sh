#!/usr/bin/env bash
# Live GPU watcher for a gaming session. Samples telemetry + scans journal for
# NVRM faults. Logs to game.log. Exits after MAX_MIN minutes or when killed.
LOG="$(dirname "$0")/game.log"
MAX_MIN=${1:-300}            # default cap 5h
INTERVAL=20                  # seconds between samples
start_epoch=$(date +%s)
since="$(date '+%Y-%m-%d %H:%M:%S')"   # only count faults from session start
{
  echo "=== GAME GPU WATCH started $since (cap ${MAX_MIN}m, every ${INTERVAL}s) ==="
  echo "cols: time | temp°C | util% | power W | sm MHz | memUsedMiB | faults_since_start | throttle | STATUS"
} >> "$LOG"

peak_temp=0
while :; do
  now_epoch=$(date +%s)
  (( (now_epoch-start_epoch)/60 >= MAX_MIN )) && { echo "$(date '+%H:%M:%S') watch cap reached, exiting" >> "$LOG"; break; }
  ts=$(date '+%H:%M:%S')
  # telemetry (timeout so a wedged GPU can't hang the watcher)
  read t u p sm mem thr < <(timeout 10 nvidia-smi \
     --query-gpu=temperature.gpu,utilization.gpu,power.draw,clocks.sm,memory.used,clocks_throttle_reasons.active \
     --format=csv,noheader,nounits 2>/dev/null | tr -d ',' )
  smi_ok=$?
  # fault scan since session start
  faults=$(journalctl --since "$since" --no-pager 2>/dev/null | grep -cE 'L2 evict failed|Xid|RmInitAdapter|Reset required|GSP-CrashCat|gpuHandleSanityCheckRegRead|GPU is probably locked|fell off the bus')
  status=OK
  [ -z "$t" ] && { status="SMI_HANG/NO_RESPONSE"; t="?"; }
  [ "$faults" != "0" ] && [ -n "$faults" ] && status="FAULTS=$faults"
  if [[ "$t" =~ ^[0-9]+$ ]]; then (( t > peak_temp )) && peak_temp=$t; (( t >= 90 )) && status="$status HOT=${t}C"; fi
  # decode throttle: 0x0 = none
  thrtxt="none"; [ -n "$thr" ] && [ "$thr" != "0x0000000000000000" ] && [ "$thr" != "0x0" ] && thrtxt="$thr"
  printf '%s | %3s | %3s | %5s | %5s | %7s | %s | %s | %s\n' \
     "$ts" "$t" "${u:-?}" "${p:-?}" "${sm:-?}" "${mem:-?}" "${faults:-?}" "$thrtxt" "$status" >> "$LOG"
  sleep "$INTERVAL"
done
echo "=== watch ended $(date '+%H:%M:%S'), peak_temp=${peak_temp}C ===" >> "$LOG"
