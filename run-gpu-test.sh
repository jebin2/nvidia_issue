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

say()  { printf '%s\n' "$*"; sync 2>/dev/null; }
step() { printf '\n######## %s\n' "$*"; sync 2>/dev/null; }

BOOT_TAG="$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null)"
OUT_DIR="$SELF_DIR/results"
if ! mkdir -p "$OUT_DIR" 2>/dev/null || [ ! -w "$OUT_DIR" ]; then
    say "WARNING: cannot write to $OUT_DIR — the USB may be mounted read-only."
    say "         Remount it rw, or results will be lost at reboot:"
    say "           mount -o remount,rw $SELF_DIR"
    OUT_DIR=/tmp
fi
LOG="$OUT_DIR/session-$(date +%Y%m%d-%H%M%S)-boot${BOOT_TAG}.log"

# This box gets power-cycled whenever the GPU wedges, and buffered writes to a
# FAT32 stick are simply lost when that happens — which is why the last log
# came back 0 bytes. Remount the stick synchronous so every write is on the
# device before the next line runs.
if ! findmnt -no OPTIONS --target "$SELF_DIR" 2>/dev/null | grep -q '\bsync\b'; then
    MNT="$(findmnt -no TARGET --target "$SELF_DIR" 2>/dev/null)"
    if [ -n "$MNT" ] && mount -o remount,sync "$MNT" 2>/dev/null; then
        echo "remounted $MNT synchronous so logs survive a power-cycle"
    else
        echo "WARNING: could not remount $MNT synchronous — if this machine is"
        echo "         power-cycled, the logs below may be lost. Remount with:"
        echo "           mount -o remount,sync $MNT"
    fi
fi

# Line-buffered, so a crash mid-run still leaves every completed line on disk.
exec > >(stdbuf -oL tee -a "$LOG") 2>&1
echo "=== run-gpu-test.sh $(date '+%F %T') ==="
sync

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
        say "  network OK"

        # The Omarchy ISO ships ONLY a local file:// mirror:
        #     [offline]
        #     Server = file:///var/cache/omarchy/mirror/offline/
        # Appending [core]/[extra] after it is NOT enough. Repo order is
        # priority order, so [offline] still wins, and its database lists
        # packages whose files are not actually on the ISO:
        #     error: failed retrieving file 'gcc-...pkg.tar.zst' from disk :
        #            Could not open file /var/cache/omarchy/mirror/offline/...
        # With a network we do not want that mirror at all, so disable it and
        # write a clean pacman.conf with the real repos first.
        if [ ! -f /etc/pacman.conf.orig ]; then
            cp -a /etc/pacman.conf /etc/pacman.conf.orig
        fi
        if ! grep -q 'gpu-livetest rewrote this' /etc/pacman.conf; then
            say "  replacing the ISO's offline-only mirror with the real repos"
            # CacheDir must be somewhere writable: the ISO's cache lives on the
            # read-only squashfs, which fails as
            #     Failure writing output to destination
            mkdir -p /tmp/pacman-cache
            {
                echo "# gpu-livetest rewrote this to reach the real Arch repos."
                echo "[options]"
                echo "Architecture = auto"
                echo "CacheDir = /tmp/pacman-cache"
                echo "ParallelDownloads = 5"
                # archiso's pacman-init.service frequently has not finished
                # populating the keyring; without this every package fails as
                # "required key missing from keyring". RAM-backed live system.
                echo "SigLevel = Never"
                echo ""
                echo "[core]"
                echo "Include = /etc/pacman.d/mirrorlist"
                echo ""
                echo "[extra]"
                echo "Include = /etc/pacman.d/mirrorlist"
                echo ""
                # LAST, so it loses every tie — but linux-omarchy-headers is
                # published nowhere else, so dropping it entirely means DKMS
                # cannot build against the running kernel at all.
                echo "[offline]"
                echo "SigLevel = Never"
                echo "Server = file:///var/cache/omarchy/mirror/offline/"
            } > /etc/pacman.conf
        fi

        # archiso often ships a mirrorlist with every Server line commented,
        # expecting reflector to fill it in. pacman then reports "no servers
        # configured for repository", which reads like a network fault.
        if ! grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist 2>/dev/null; then
            say "  mirrorlist has no active Server — writing known-good mirrors"
            cp -a /etc/pacman.d/mirrorlist "/etc/pacman.d/mirrorlist.bak.$$" 2>/dev/null
            cat > /etc/pacman.d/mirrorlist <<'MIRROREOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://in-mirror.garudalinux.org/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
MIRROREOF
        fi
        say "  active mirrors: $(grep -cE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist 2>/dev/null)"

        # An interrupted pacman leaves db.lck behind and every later run dies
        # instantly with "unable to lock database", which looks just like a
        # missing package. Earlier runs here were interrupted mid-install.
        if [ -f /var/lib/pacman/db.lck ] && ! pgrep -x pacman >/dev/null 2>&1; then
            say "  clearing a stale pacman db.lck left by an interrupted run"
            rm -f /var/lib/pacman/db.lck
        fi

        say "  refreshing databases"
        pacman -Syy --noconfirm --cachedir /tmp/pacman-cache 2>&1 | tail -8

        KVER="$(uname -r)"
        say "  running kernel: $KVER — looking for matching headers"
        HDR=""
        # Order matters: linux-headers builds against Arch's stock kernel, not
        # against 7.2.8-9-omarchy, so it is a wrong answer rather than a
        # fallback. Only accept it if the running kernel is actually stock.
        for cand in "linux-${KVER##*-}-headers" linux-omarchy-headers; do
            if pacman -Si "$cand" >/dev/null 2>&1; then HDR="$cand"; break; fi
        done
        if [ -n "$HDR" ] && ! pacman -Sp "$HDR" >/dev/null 2>&1; then
            say "  WARNING: $HDR is in a repo database but its file is missing"
            say "  from the ISO mirror, and it is published nowhere else. DKMS"
            say "  cannot build against $KVER. The driver step will be skipped;"
            say "  the load test under nouveau still runs and is the useful part."
        fi
        if [ -z "$HDR" ] && [ -d "/usr/lib/modules/$KVER/build" ]; then
            say "  headers already present at /usr/lib/modules/$KVER/build"
            HDR="SKIP"
        fi

        if [ -z "$HDR" ]; then
            say
            say "  STOP: no kernel headers package is available in the configured repos."
            say "  DKMS cannot build the NVIDIA module without headers for $KVER, and"
            say "  Arch's prebuilt nvidia packages only match the stock 'linux' kernel."
            say "  Tier 2 is not possible on this ISO. Tier 1 results below are still valid."
        else
            say "  found headers package: $HDR"
            # One at a time: pacman aborts the entire transaction on the first
            # unresolvable target, so a missing vulkan-tools also cost us the
            # driver last run. Each package now fails on its own.
            # Every package failed with "could not extract ... (Write failed)":
            # the live overlay was full, not a pacman or repo problem. Report
            # the space, and grow the copy-on-write tmpfs if it is undersized.
            say "  free space on / : $(df -h / 2>/dev/null | awk 'NR==2{print $4" of "$2}')"
            COW=/run/archiso/cowspace
            if [ -d "$COW" ]; then
                say "  cowspace        : $(df -h "$COW" 2>/dev/null | awk 'NR==2{print $4" free of "$2}')"
                avail_k=$(df -k "$COW" 2>/dev/null | awk 'NR==2{print $4}')
                if [ "${avail_k:-0}" -lt 3145728 ]; then
                    say "  under 3 GiB free — growing the cow tmpfs to 75% of RAM"
                    mount -o remount,size=75% "$COW" 2>&1 | sed 's/^/    /'
                    say "  cowspace now    : $(df -h "$COW" 2>/dev/null | awk 'NR==2{print $4" free"}')"
                fi
            fi

            # Order matters. vulkan-tools and mesa-utils are ~100 MB and are
            # what the load test needs; the driver is 1.5 GB and may not be
            # installable here at all. Get the cheap, decisive thing first so a
            # space or headers failure cannot cost us the load test too.
            say "  installing load tools first (small), driver after (large)"
            ok=1
            pkgs="vulkan-tools mesa-utils vulkan-nouveau vulkan-intel vulkan-icd-loader dkms base-devel nvidia-dkms nvidia-utils"
            [ "$HDR" = "SKIP" ] || pkgs="$HDR $pkgs"
            for pkg in $pkgs; do
                if out=$(pacman -S --needed --noconfirm --cachedir /tmp/pacman-cache "$pkg" 2>&1); then
                    say "    installed  $pkg"
                else
                    say "    FAILED     $pkg"
                    # Say WHY. "FAILED" with no reason cost several boots.
                    printf '%s\n' "$out" | grep -iE 'error|warning|not found|lock|No space|signature|key' \
                        | head -5 | sed 's/^/               /'
                    case "$pkg" in nvidia-dkms|"$HDR") ok=0 ;; esac
                fi
            done
            if [ "$ok" = 1 ]; then
                say "  driver packages in place; loading the module"
                modprobe nvidia 2>&1 | sed 's/^/    /'
                modprobe nvidia_drm 2>&1 | sed 's/^/    /'
                say "  modules now loaded: $(lsmod | awk '/^nvidia/ {printf "%s ", $1}')"
                command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi 2>&1 | head -12 | sed 's/^/    /'
            else
                say "  NVIDIA driver could not be installed. Tier 1 results still stand,"
                say "  and any load tools that did install are used below."
            fi
        fi
    fi
fi

# ------------------------------------------------------------------- tier one
# The GPU keeps entering D3cold while we set up, then failing to come back —
# three boots have now died that way before any load was applied. Pin runtime
# PM on so it cannot suspend, which isolates "does it survive load" from "does
# it survive a resume". Both are real faults; they need testing separately.
step "pinning runtime PM on (so RTD3 cannot destroy the load test)"
for d in /sys/bus/pci/devices/0000:01:00.*; do
    [ -w "$d/power/control" ] || continue
    echo on > "$d/power/control" 2>/dev/null \
        && say "  ${d##*/}  power/control=on  (was auto)" \
        || say "  ${d##*/}  could not pin"
done
say "  to disable it from boot instead, add to the kernel line: nouveau.runpm=0"

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
