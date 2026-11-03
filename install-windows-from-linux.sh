#!/usr/bin/env bash
# install-windows-from-linux.sh — install Windows 11 without using Setup.
#
# Windows 11 build 26300's Setup refuses to list any drive on this machine even
# with Intel VMD disabled and the NVMe sitting plainly at 0000:02:00.0. Rather
# than keep fighting its storage detection, apply the image directly: create the
# partition, unpack install.swm onto it, and let bcdboot (run once from WinPE)
# write the boot entry. This is a long-standing, supported way to deploy Windows
# and it does not care what Setup's UI thinks.
#
# ONLY the unallocated tail of the disk is touched. nvme0n1p1 (ESP) and
# nvme0n1p2 (Linux) are never written to.
#
# Usage: sudo bash install-windows-from-linux.sh [image-index]   (default 6 = Pro)

set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

DISK=/dev/nvme0n1
IDX="${1:-6}"
SRC=/run/media/jebin/WININSTALL
MNT=/mnt/windows

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

[ -d "$SRC" ] || die "installer stick not mounted at $SRC"
[ -f "$SRC/sources/install.swm" ] || die "install.swm not found on the stick"

# --------------------------------------------------- confirm the free space
P2END=$(( $(cat /sys/block/nvme0n1/nvme0n1p2/start) + $(cat /sys/block/nvme0n1/nvme0n1p2/size) - 1 ))
TOT=$(cat /sys/block/nvme0n1/size)
START=$((P2END + 1))
END=$((TOT - 34))
FREE=$((END - START + 1))
echo "existing partitions are left untouched:"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DISK" | sed 's/^/  /'
echo
printf 'new partition : sectors %s..%s  (%.2f GiB)\n' "$START" "$END" "$(python3 -c "print($FREE*512/2**30)")"
echo "edition       : index $IDX ($(wimlib-imagex info "$SRC/sources/install.swm" "$IDX" 2>/dev/null | awk -F': *' '/^Name:/{print $2; exit}'))"
echo
[ "$FREE" -gt 100000000 ] || die "not enough unallocated space"
RESUME=0
if [ -b "${DISK}p3" ]; then
    if blkid "${DISK}p3" 2>/dev/null | grep -q 'TYPE="ntfs"'; then
        echo "NOTE: ${DISK}p3 already exists and is NTFS — reusing it."
        RESUME=1
    else
        die "${DISK}p3 exists but is not NTFS. Inspect it before continuing."
    fi
fi

read -r -p "Type INSTALL to continue: " ans
[ "$ans" = "INSTALL" ] || die "aborted"

# ------------------------------------------------------------- partition
if [ "$RESUME" = 0 ]; then
    echo "==> creating ${DISK}p3 (Microsoft basic data)"
    sgdisk -n "3:${START}:${END}" -t 3:0700 -c 3:"Windows" "$DISK"
    partprobe "$DISK"; udevadm settle; sleep 2
    [ -b "${DISK}p3" ] || die "${DISK}p3 did not appear"

    echo "==> formatting NTFS"
    mkfs.ntfs -Q -L Windows "${DISK}p3"
fi

# ----------------------------------------------------------------- apply
umount "${DISK}p3" 2>/dev/null || true
echo "==> applying image $IDX directly to ${DISK}p3 (~27 GB; several minutes)"
# Target is the raw volume on purpose: wimlib then uses its NTFS-3G backend and
# writes security descriptors, DOS short names and reparse points. Applying
# into a mounted filesystem loses all of those, and Windows will not boot.
# --ref is required because the image spans install.swm/2/3.
wimlib-imagex apply "$SRC/sources/install.swm" "$IDX" "${DISK}p3" --ref="$SRC/sources/install*.swm"

echo "==> verifying"
ntfsls -l "${DISK}p3" 2>/dev/null | grep -iE '^.*(Windows|Program Files|Users)' | head -5 \
    || echo "  (ntfsls unavailable; check after the first boot instead)"
sync

cat <<'EOT'

Done. The Windows files are on nvme0n1p3, but it is NOT bootable yet — the
boot entry has to be written by Windows' own bcdboot, which only runs under
Windows. One more step, and it takes about a minute:

  1. Boot the USB again and reach Windows Setup.
  2. Press Shift + F10 for a command prompt (do NOT use the drive screen).
  3. Identify the volumes:

         diskpart
         list volume
         exit

     Note the letter of the NTFS volume labelled "Windows" (likely C: or D:)
     and the letter of the FAT32 EFI partition (it may have none — if so, in
     diskpart: select volume <n>, assign letter=S, exit).

  4. Write the boot files, substituting your letters:

         bcdboot W:\Windows /s S: /f UEFI

  5. Reboot. Windows starts its first-boot setup (OOBE).

This writes a Windows entry into the shared ESP alongside Limine. Your Linux
entry is not removed, but Windows will put itself first in the UEFI boot order
-- fix that afterwards with efibootmgr or the BIOS boot-order menu.
EOT
