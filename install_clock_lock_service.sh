#!/usr/bin/env bash
# Install + enable the automatic NVIDIA clock-lock service.
# Run as: sudo bash install_clock_lock_service.sh
set -e
cp "$(dirname "$0")/nvidia-clock-lock.service" /etc/systemd/system/nvidia-clock-lock.service
systemctl daemon-reload
systemctl enable --now nvidia-clock-lock.service
systemctl status nvidia-clock-lock.service --no-pager | head -8
echo
nvidia-smi --query-gpu=clocks.max.gr,clocks.mem --format=csv,noheader
echo "Done: clocks lock automatically on every boot."
