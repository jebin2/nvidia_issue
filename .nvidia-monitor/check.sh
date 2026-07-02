#!/usr/bin/env bash
# NVIDIA RTD3 stability check — appends one line to monitor.log
LOG="$(dirname "$0")/monitor.log"
now=$(date '+%Y-%m-%d %H:%M:%S')
boot=$(uptime -s)
dpm=$(grep -i '^DynamicPowerManagement:' /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}')
status=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status 2>/dev/null)
# error signatures in current boot's journal
errs=$(journalctl -b --no-pager 2>/dev/null | grep -cE 'L2 evict failed|Xid|RmInitAdapter|GFW_BOOT|SanityCheckRegRead')
# is the GPU responsive (smi must not hang)
if timeout 12 nvidia-smi --query-gpu=pstate,temperature.gpu --format=csv,noheader >/dev/null 2>&1; then smi=OK; else smi=FAIL/HANG; fi
verdict=OK
[ "$errs" != "0" ] && verdict="ERRORS=$errs"
[ "$smi" != "OK" ] && verdict="$verdict SMI=$smi"
[ "$dpm" != "0" ] && verdict="$verdict DPM=$dpm(!)"
printf '%s | boot=%s | dpm=%s | status=%-9s | err_sigs=%s | smi=%s | => %s\n' \
  "$now" "$boot" "$dpm" "$status" "$errs" "$smi" "$verdict" >> "$LOG"
echo "$verdict"
