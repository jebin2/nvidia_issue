#!/usr/bin/env bash
# prep-test-usb.sh — add a writable TEST partition to the Omarchy live USB and
# put the GPU test scripts on it.
#
# The ISO occupies only ~6.1 GiB of a 28.7 GiB stick, so there is unallocated
# space after it. This appends a FAT32 partition there and copies the scripts
# in. The ISO partitions are not touched, so the stick still boots exactly as
# it does now; results are written to the USB and survive the reboot.
#
# Usage: sudo bash prep-test-usb.sh [/dev/sdX]      (default: /dev/sda)

set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

DEV="${1:-/dev/sda}"
LABEL="GPUTEST"
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------- identify
# Refuse to touch anything that is not demonstrably the Omarchy stick. A wrong
# device here destroys a disk, so check the model AND the ISO label, not just
# the node name.
[ -b "$DEV" ] || die "$DEV is not a block device"
MODEL="$(lsblk -dno MODEL "$DEV" 2>/dev/null | xargs || true)"
RM_FLAG="$(lsblk -dno RM "$DEV" 2>/dev/null | xargs || true)"
P1LABEL="$(lsblk -no LABEL "${DEV}1" 2>/dev/null | head -1 | xargs || true)"

echo "device : $DEV"
echo "model  : ${MODEL:-unknown}"
echo "removable: $RM_FLAG"
echo "part1 label: ${P1LABEL:-none}"

[ "$RM_FLAG" = "1" ] || die "$DEV is not removable — refusing. This looks like an internal disk."
case "$P1LABEL" in
    OMARCHY*|ARCH*) ;;
    *) die "${DEV}1 is labelled '${P1LABEL:-none}', not an Omarchy/Arch ISO. Refusing." ;;
esac

if mount | grep -q "^${DEV}"; then
    echo
    echo "Unmounting existing mounts on $DEV:"
    mount | awk -v d="$DEV" '$1 ~ "^"d {print $3}' | while read -r mp; do
        umount -v "$mp" || die "could not unmount $mp"
    done
fi

# ------------------------------------------------------------------ free space
TOT=$(blockdev --getsz "$DEV")
LAST=0
for p in /sys/block/$(basename "$DEV")/$(basename "$DEV")*; do
    [ -r "$p/start" ] || continue
    e=$(( $(cat "$p/start") + $(cat "$p/size") - 1 ))
    [ "$e" -gt "$LAST" ] && LAST=$e
done
START=$((LAST + 1))
FREE=$((TOT - START - 34))
echo
echo "disk sectors    : $TOT"
echo "last used       : $LAST"
echo "new partition   : start $START, $FREE sectors ($((FREE/2/1024/1024)) GiB)"
[ "$FREE" -gt 2097152 ] || die "less than 1 GiB free after the ISO — nothing to do"

NEXT=$(( $(ls -1 /sys/block/$(basename "$DEV")/ | grep -c "^$(basename "$DEV")[0-9]") + 1 ))
PART="${DEV}${NEXT}"
echo "will create     : $PART"

if [ -e "$PART" ]; then
    die "$PART already exists. If it is a previous TEST partition, just mount it and copy the scripts by hand."
fi

echo
read -r -p "Append $PART to $DEV and format it FAT32? The ISO partitions are untouched. [y/N] " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "aborted by user"

# --------------------------------------------------------------------- create
# sfdisk --append works on both MBR and GPT and leaves existing entries alone.
echo "$START,$FREE,0c" | sfdisk --append --no-reread "$DEV" || die "sfdisk failed — nothing was formatted"
partprobe "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 2
[ -b "$PART" ] || die "$PART did not appear. Replug the stick and re-run."

mkfs.vfat -F32 -n "$LABEL" "$PART" || die "mkfs.vfat failed"

# ----------------------------------------------------------------------- copy
MP="$(mktemp -d)"
mount "$PART" "$MP" || die "could not mount $PART"
for f in run-gpu-test.sh gpu-livetest; do
    [ -f "$SRC/$f" ] || die "$SRC/$f not found"
    cp -v "$SRC/$f" "$MP/"
done
mkdir -p "$MP/results"
cat > "$MP/README.txt" <<'EOT'
GPU test stick
==============

Boot this USB, choose the Omarchy live / "install medium" entry. If the
installer appears, press Ctrl+Alt+F2 and log in as root (no password) — the
installer is harmless sitting on tty1, and nothing is written to the internal
disk unless you tell the installer to.

Find this partition (labelled GPUTEST) and run:

    cd /run/media/*/GPUTEST            # or: mount /dev/sda3 /mnt && cd /mnt
    bash run-gpu-test.sh               # nouveau only, no network needed
    bash run-gpu-test.sh --install-driver   # also install the real NVIDIA driver

Results are written to the results/ folder on this stick, tagged with the boot
id, so repeated boots accumulate instead of overwriting.

Run it on 2-3 separate boots: the boot-time PMU halt shows up in roughly one
boot in three, so a single clean run does not mean much.

Back in CachyOS:  cd ~/nvidia_issue && claude --resume
EOT
sync
echo
echo "contents of $PART:"
ls -la "$MP" | sed 's/^/  /'
umount "$MP" && rmdir "$MP"

echo
echo "Done. $PART is labelled $LABEL and holds run-gpu-test.sh, gpu-livetest and README.txt."
echo "The stick still boots the ISO exactly as before."
