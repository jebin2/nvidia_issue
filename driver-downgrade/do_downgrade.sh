#!/usr/bin/env bash
# Downgrade NVIDIA driver 610.43.02 (open, prebuilt) -> 595.71.05 (open, DKMS)
# to test whether the load-triggered GSP firmware crash is a 610-branch regression.
# RUN FROM A TTY (Ctrl+Alt+F3), as: sudo bash do_downgrade.sh
set -u
CACHE=/var/cache/pacman/pkg
DKMS_PKG=/home/jebin/nvidia_issue/driver-downgrade/nvidia-open-dkms-595.71.05-2-x86_64.pkg.tar.zst
V=595.71.05

echo "==> Verifying package files exist..."
US=()
for p in nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings libxnvctrl; do
  f=$(ls "$CACHE/${p}-${V}-"*-x86_64*.pkg.tar.zst 2>/dev/null | grep -v '\.sig' | head -1)
  if [ -z "$f" ]; then echo "MISSING: ${p}-${V}"; exit 1; fi
  US+=("$f")
done
[ -f "$DKMS_PKG" ] || { echo "MISSING dkms pkg: $DKMS_PKG"; exit 1; }
echo "    all present."

echo "==> Step 1/3: remove prebuilt 610 kernel-module packages..."
pacman -Rdd --noconfirm linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open || {
  echo "removal failed; aborting (no changes to driver yet)"; exit 1; }

echo "==> Step 2/3: install 595 DKMS module + downgrade userspace (review & confirm)..."
pacman -U "$DKMS_PKG" "${US[@]}" || {
  echo "!! install FAILED. ROLL BACK NOW: sudo bash /home/jebin/nvidia_issue/driver-downgrade/rollback.sh"; exit 1; }

echo "==> Step 3/3: DKMS build result for running + installed kernels:"
dkms status
echo
echo "==> Check: did the nvidia module build for kernel $(uname -r)?"
if dkms status 2>/dev/null | grep -q "$(uname -r).*installed"; then
  echo "   ✅ module built for current kernel."
else
  echo "   ⚠️  NOT built for $(uname -r) (driver too old for this kernel?)."
  echo "      If so, boot the LTS kernel (6.18.x) at the Limine menu instead."
fi
echo
echo "NEXT (only if build looks OK): pin + rebuild initramfs + reboot:"
echo "  sudo bash /home/jebin/nvidia_issue/driver-downgrade/pin_and_finish.sh"
echo "If anything looks wrong: sudo bash /home/jebin/nvidia_issue/driver-downgrade/rollback.sh"
