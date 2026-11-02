#!/usr/bin/env bash
# run-gpu-test.sh — the whole live-USB GPU test, run from the USB itself.
#
# Boot the Omarchy USB, pick the live/"install medium" entry, get a terminal
# (Ctrl+Alt+F2 if the installer is in the way, log in as root, no password),
# then run this from wherever the USB's TEST partition is mounted:
#
#   bash /run/media/*/GPUTEST/run-gpu-test.sh                  tier 1: nouveau
#   bash /run/media/*/GPUTEST/run-gpu-test.sh --install-driver tier 2: real driver
#
# Tier 1 needs nothing. It records how nouveau behaves on this GPU. Nouveau on
# Ada drives the same AD107 through the same GSP firmware that crashes under
# NVIDIA's driver, so:
#     nouveau clean   -> the bug is NVIDIA's driver
#     nouveau faults  -> firmware or silicon, and no driver will fix it
#
# Tier 2 installs the real NVIDIA driver into the live session's RAM overlay
# and tests the documented failure modes on a kernel never tried before
# (linux-omarchy 7.2.8 vs the 6.18-LTS and 7.1.2 already tested). Needs
# network. It cannot work without kernel headers for the running kernel, and
# the script says so plainly rather than half-failing.
#
# Nothing here touches the internal disk. Results are written next to this
# script on the USB, so they survive the reboot.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LOAD_SECS="${LOAD_SECS:-180}"
DO_INSTALL=0
[ "${1:-}" = "--install-driver" ] && DO_INSTALL=1
[ "${1:-}" = "--help" ] && { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

say()  { printf '%s\n' "$*"; }
step() { printf '\n######## %s\n' "$*"; }

BOOT_TAG="$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null)"
OUT_DIR="$SELF_DIR/results"
if ! mkdir -p "$OUT_DIR" 2>/dev/null || [ ! -w "$OUT_DIR" ]; then
    say "WARNING: cannot write to $OUT_DIR — the USB may be mounted read-only."
    say "         Remount it rw, or results will be lost at reboot:"
    say "           mount -o remount,rw $SELF_DIR"
    OUT_DIR=/tmp
fi
LOG="$OUT_DIR/session-$(date +%Y%m%d-%H%M%S)-boot${BOOT_TAG}.log"

# ---------------------------------------------------------------- environment
step "where am I"
say "  script dir : $SELF_DIR"
say "  results to : $OUT_DIR"
say "  kernel     : $(uname -r)"
say "  live ISO   : $(cat /run/archiso/bootmnt/arch/version 2>/dev/null || echo unknown)"

# ------------------------------------------------------------------- tier two
if [ "$DO_INSTALL" = 1 ]; then
    step "tier 2: installing the real NVIDIA driver"

    if ! ping -c1 -W3 archlinux.org >/dev/null 2>&1; then
        say "  No network. Connect first, then re-run:"
        say "    ip link                                    # find the interface"
        say "    dhcpcd <wired-iface>                       # wired"
        say "    iwctl station <wifi-iface> connect \"SSID\"   # wifi"
        say
        say "  Continuing with tier 1 only."
    else
        say "  network OK; refreshing databases"
        pacman -Sy --noconfirm 2>&1 | tail -5

        KVER="$(uname -r)"
        say "  running kernel: $KVER — looking for matching headers"
        HDR=""
        for cand in linux-omarchy-headers linux-headers; do
            if pacman -Si "$cand" >/dev/null 2>&1; then HDR="$cand"; break; fi
        done

        if [ -z "$HDR" ]; then
            say
            say "  STOP: no kernel headers package is available in the configured repos."
            say "  DKMS cannot build the NVIDIA module without headers for $KVER, and"
            say "  Arch's prebuilt nvidia packages only match the stock 'linux' kernel."
            say "  Tier 2 is not possible on this ISO. Tier 1 results below are still valid."
        else
            say "  found headers package: $HDR"
            if pacman -S --needed --noconfirm "$HDR" dkms base-devel \
                   nvidia-dkms nvidia-utils vulkan-tools mesa-utils 2>&1 | tail -15; then
                say "  install finished; loading the module"
                modprobe nvidia 2>&1 | sed 's/^/    /'
                modprobe nvidia_drm 2>&1 | sed 's/^/    /'
                say "  modules now loaded: $(lsmod | awk '/^nvidia/ {printf "%s ", $1}')"
                command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi 2>&1 | head -12 | sed 's/^/    /'
            else
                say "  driver install FAILED — see output above. Tier 1 results still stand."
            fi
        fi
    fi
fi

# ------------------------------------------------------------------- tier one
step "characterising the GPU"
LIVETEST="$SELF_DIR/gpu-livetest"
if [ ! -f "$LIVETEST" ]; then
    say "  ERROR: gpu-livetest is missing from $SELF_DIR — cannot continue."
    exit 1
fi
OUT_DIR="$OUT_DIR" LOAD_SECS="$LOAD_SECS" bash "$LIVETEST" --load

step "done"
say "  Results in: $OUT_DIR"
ls -la "$OUT_DIR" 2>/dev/null | sed 's/^/    /'
say
say "  Run this on 2-3 separate boots before concluding anything: the boot-time"
say "  PMU halt appears in roughly 1 boot in 3, so one clean run proves little."
say
say "  Back in CachyOS:  cd ~/nvidia_issue && claude --resume"
say "  then say: read the USB test results"
