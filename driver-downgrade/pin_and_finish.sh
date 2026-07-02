#!/usr/bin/env bash
# Pin the 595 driver so updates don't undo it, rebuild initramfs, then you reboot.
# Run as: sudo bash pin_and_finish.sh
set -u
PINS="nvidia-open-dkms nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings libxnvctrl"

echo "==> Adding IgnorePkg pin to /etc/pacman.conf (if not already present)..."
if grep -qE '^IgnorePkg' /etc/pacman.conf; then
  echo "    NOTE: an IgnorePkg line already exists — add these manually if needed:"
  echo "    $PINS"
else
  cp /etc/pacman.conf /etc/pacman.conf.bak.$(date +%s)
  # insert under [options]
  sed -i "/^\[options\]/a IgnorePkg = $PINS" /etc/pacman.conf
  echo "    pinned: $PINS"
fi

echo "==> Rebuilding initramfs / Limine entries..."
limine-update

echo
echo "✅ Done. Now REBOOT and test under load."
echo "   To undo the pin later: remove the IgnorePkg line from /etc/pacman.conf"
