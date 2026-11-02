#!/usr/bin/env bash
# fix-wifi.sh — the Omarchy live ISO ships no firmware for this machine's Wi-Fi.
#
#   iwlwifi 0000:00:14.3: Direct firmware load for iwlwifi-so-a0-hr-b0-89.ucode
#                         failed with error -2      (ENOENT — the file is absent)
#   iwlwifi 0000:00:14.3: no suitable firmware found!
#
# The card is a Killer AX1650i / Intel AX201 (CNVi at 00:14.3). iwd showing an
# empty `device list` is a symptom, not the cause: with no firmware the driver
# never registers an interface for iwd to find.
#
# The .ucode files beside this script came from the installed CachyOS system,
# which drives this same card, and are already decompressed — the live kernel
# may not have zstd firmware support built in, and plain .ucode always works.
#
# Usage:  bash fix-wifi.sh        (as root, in the live session)

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "==> copying firmware into /lib/firmware"
cp -v "$HERE"/firmware/iwlwifi-so-a0-hr-b0-*.ucode /lib/firmware/ || {
    echo "copy failed"; exit 1; }

echo "==> reloading iwlwifi"
modprobe -r iwlwifi 2>/dev/null
sleep 1
modprobe iwlwifi

echo "==> waiting for an interface"
IFACE=""
for _ in $(seq 1 15); do
    IFACE="$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)"
    [ -n "$IFACE" ] && break
    sleep 1
done

if [ -z "$IFACE" ]; then
    echo
    echo "No wl* interface appeared. What the kernel says now:"
    dmesg | grep -i iwlwifi | tail -15
    echo
    echo "Fall back to wired, or tether a phone over USB:"
    echo "    ip link set enp109s0 up && dhcpcd enp109s0"
    exit 1
fi

echo "    interface: $IFACE"
rfkill unblock all 2>/dev/null
ip link set "$IFACE" up
systemctl start iwd
sleep 2

echo
echo "Connect with:"
echo "    iwctl station $IFACE scan"
echo "    iwctl station $IFACE get-networks"
echo "    iwctl station $IFACE connect \"YOUR_SSID\""
echo
echo "Verify:  ping -c3 archlinux.org"
