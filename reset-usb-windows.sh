#!/usr/bin/env bash
# reset-usb-windows.sh — wipe the stick completely and rebuild it as a single
# Windows installer. One partition, one bootloader, no ambiguity about what
# the firmware will pick.
#
# The previous layout had TWO EFI System Partitions on one stick (Omarchy's
# and Windows'), and firmware boots the first one it finds — which is why it
# kept starting Omarchy.
#
# Usage: sudo bash reset-usb-windows.sh [/dev/sdX]

set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

DEV="${1:-/dev/sda}"
STAGE=/home/jebin/win-installer-staging
LABEL=WININSTALL

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ safety
[ -b "$DEV" ] || die "$DEV is not a block device"
[ -d "$STAGE" ] || die "staging directory $STAGE is missing — nothing to write"
case "$DEV" in *nvme*|*mmcblk*) die "$DEV looks like an internal disk. Refusing." ;; esac
[ "$(lsblk -dno RM "$DEV" | xargs)" = "1" ] || die "$DEV is not removable. Refusing."

SIZE=$(lsblk -dno SIZE "$DEV" | xargs)
MODEL=$(lsblk -dno MODEL "$DEV" | xargs)
echo "target : $DEV  ($SIZE, $MODEL)"
echo "source : $STAGE  ($(du -sh "$STAGE" | cut -f1))"
echo
echo "This ERASES EVERYTHING on $DEV, including the Omarchy ISO."
read -r -p "Type ERASE to continue: " ans
[ "$ans" = "ERASE" ] || die "aborted"

# --------------------------------------------------------------- unmount
for mp in $(lsblk -no MOUNTPOINT "$DEV" | grep -v '^$'); do
    echo "unmounting $mp"; umount "$mp" || die "could not unmount $mp"
done

# ------------------------------------------------------------------- wipe
echo "==> wiping signatures and partition table"
wipefs -a "$DEV"
# The old ISO9660 signature sits at 0x8000 and survives a table rewrite;
# lsblk kept reporting the whole disk as iso9660 because of it. Zero the
# first 16 MiB so nothing of the old layout can be detected.
dd if=/dev/zero of="$DEV" bs=1M count=16 oflag=direct conv=fsync status=none
sync

echo "==> creating a single EFI System Partition across the whole stick"
sfdisk "$DEV" <<'SFD'
label: gpt
,,U
SFD
partprobe "$DEV"; udevadm settle; sleep 2

PART="${DEV}1"
[ -b "$PART" ] || die "$PART did not appear"

echo "==> formatting FAT32"
mkfs.vfat -F32 -n "$LABEL" "$PART"

# ------------------------------------------------------------------- copy
MNT=$(mktemp -d)
mount "$PART" "$MNT"
echo "==> copying the installer (8.5 GB at ~8 MB/s — about 18 minutes)"
cp -r "$STAGE"/. "$MNT"/
sync

echo
echo "==> verifying"
ok=1
for f in bootmgr.efi efi/boot/bootx64.efi sources/boot.wim \
         sources/install.swm sources/install2.swm sources/install3.swm setup.exe; do
    if [ -e "$MNT/$f" ]; then printf '  OK  %s\n' "$f"
    else printf '  MISSING  %s\n' "$f"; ok=0; fi
done
df -h "$MNT" | tail -1
umount "$MNT" && rmdir "$MNT"
sync

[ "$ok" = 1 ] || die "the installer is incomplete — do not boot it"
echo
echo "Done. $DEV is now a single-partition Windows installer labelled $LABEL."
echo "Reboot, F12, pick the USB. It can only boot Windows Setup now."
