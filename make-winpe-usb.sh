#!/usr/bin/env bash
# make-winpe-usb.sh — add a bootable Windows PE environment to the test stick,
# for running Acer's BIOS flasher without installing Windows.
#
# Why this works: the Windows installer boots into WinPE, which runs entirely
# from RAM. Shift+F10 at the first screen gives a command prompt. Acer's
# H2OFFT flasher runs there and can load its H2OFFT64.sys kernel driver, which
# is the thing Wine cannot provide and the only reason a Windows kernel is
# needed at all. Nothing is installed and the internal disk is never touched.
#
# sources/install.wim is deliberately excluded: it is 8.15 GB, over FAT32's 4 GB
# per-file limit, and is only needed to actually install Windows — which we are
# not doing. Everything required to reach the command prompt is in boot.wim.
#
# Usage: bash make-winpe-usb.sh [/path/to/windows.iso] [/path/to/mounted/usb]

set -uo pipefail

ISO="${1:-/home/jebin/windows-vm/Windows11_Client_x64_en-us_26300_9457.iso}"
DEST="${2:-/run/media/jebin/GPUTEST}"
BIOSDIR=/home/jebin

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$ISO" ]  || die "ISO not found: $ISO"
[ -d "$DEST" ] || die "USB not mounted at $DEST (udisksctl mount -b /dev/sda3)"
[ -w "$DEST" ] || die "$DEST is not writable"

avail=$(df -BM --output=avail "$DEST" | tail -1 | tr -dc '0-9')
say "destination : $DEST (${avail} MiB free)"
[ "${avail:-0}" -gt 2048 ] || die "need at least 2 GiB free on the stick"

say "extracting the installer (excluding install.wim, 8.15 GB, > FAT32 limit)"
7z x -y -o"$DEST" "$ISO" -xr'!sources/install.wim' >/dev/null 2>&1 \
    || die "extraction failed"

# The firmware boots \EFI\BOOT\BOOTX64.EFI. Without it the stick is just files.
BOOTEFI=""
for c in "$DEST/efi/boot/bootx64.efi" "$DEST/EFI/BOOT/BOOTX64.EFI" "$DEST/EFI/Boot/bootx64.efi"; do
    [ -f "$c" ] && { BOOTEFI="$c"; break; }
done
[ -n "$BOOTEFI" ] || die "no EFI/BOOT/BOOTX64.EFI after extraction — this stick will not boot"
say "boot loader : ${BOOTEFI#$DEST/}"

[ -f "$DEST/sources/boot.wim" ] || die "sources/boot.wim missing — WinPE cannot start"
say "boot.wim    : $(du -h "$DEST/sources/boot.wim" | cut -f1)"
[ -f "$DEST/sources/install.wim" ] && die "install.wim was copied; FAT32 cannot hold it"

say "copying the Acer BIOS packages"
for f in "$BIOSDIR"/BIOS_Acer_1.1[68]_A_A.zip; do
    [ -f "$f" ] && cp -v "$f" "$DEST/"
done
# The already-extracted flasher saves unpacking it again inside WinPE.
if [ -d /home/jebin/bios-extracted ]; then
    mkdir -p "$DEST/bios-extracted"
    cp -v /home/jebin/bios-extracted/* "$DEST/bios-extracted/" 2>/dev/null
fi

cat > "$DEST/FLASH-BIOS.txt" <<'EOT'
Flashing the Acer BIOS from WinPE
=================================

1. Boot this stick and pick the Windows entry (F12 at the Acer logo).
2. At the first Windows Setup screen press  Shift + F10  -> a command prompt.
   DO NOT click Install. Nothing is written to the internal disk.
3. Find the stick's drive letter:

       wmic logicaldisk get name,volumename
       dir D:\        (try D:, E:, F: until you see FLASH-BIOS.txt)

4. Run the flasher:

       D:
       cd bios-extracted
       H2OFFT-Wx64.exe ZGRJ.fd

   or run the original self-extractor instead, which unpacks and launches it:

       cd \
       ZGRJ_118.exe

5. Keep the machine ON AC POWER. Do not interrupt it. It reboots on its own.

If H2OFFT reports it cannot load its driver, WinPE is refusing the unsigned
kernel driver. Try:

       bcdedit /set testsigning on        (then reboot back into WinPE)

and if that fails, this route will not work and a full Windows install is the
only remaining option.

AFTER FLASHING, verify from Linux:

       cat /sys/class/dmi/id/bios_version      # expect V1.18, not V1.13
       cat /sys/class/dmi/id/bios_date

WHAT YOU ARE FLASHING
  ZGRJ.fd, 22,193,072 bytes, declares $V1.18 and $ZGRJ, and contains this
  machine's ESRT GUID 41434552-648c-4365-bafd-eb869f00170f, so it is built for
  this board.

  WARNING: platform.ini in this package has an EMPTY [Platform_Check] section,
  so H2OFFT will NOT validate the model before writing. Confirm your label
  reads PHN16-71 and not PHN16-72 before you start.
EOT

sync
say ""
say "done. Stick now holds both the Omarchy live ISO and Windows PE."
say "Read FLASH-BIOS.txt on the stick for the flashing steps."
