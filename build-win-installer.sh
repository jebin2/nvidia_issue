#!/usr/bin/env bash
# Put a full Windows installer on the FAT32 stick.
#
# install.wim is 8.15 GB and FAT32 caps a single file at 4 GB. wimlib splits it
# into .swm chunks that Windows Setup reads natively, so the stick stays FAT32
# and needs no NTFS driver shim to boot.
set -euo pipefail
ISO="${1:-/home/jebin/windows-vm/Windows11_Client_x64_en-us_26300_9457.iso}"
MP="${2:-/run/media/jebin/GPUTEST}"
WORK=/home/jebin/windows-vm/_wim

mkdir -p "$WORK"
echo "==> extracting sources/install.wim from the ISO"
7z x -y -o"$WORK" "$ISO" sources/install.wim >/dev/null
ls -la "$WORK/sources/install.wim"

echo "==> splitting into <4 GiB chunks onto the stick"
rm -f "$MP"/sources/install*.swm
wimlib-imagex split "$WORK/sources/install.wim" "$MP/sources/install.swm" 3800

echo "==> verifying"
ls -la "$MP"/sources/install*.swm
wimlib-imagex info "$MP/sources/install.swm" | head -12

echo "==> cleaning up the 8 GB intermediate"
rm -rf "$WORK"
sync
echo "done"
