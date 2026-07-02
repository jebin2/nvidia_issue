#!/usr/bin/env bash
# Roll back to NVIDIA 610.43.02 (open, prebuilt) — undoes do_downgrade.sh.
# Run as: sudo bash rollback.sh   (all 610 packages are in cache; no network needed)
set -u
CACHE=/var/cache/pacman/pkg
V=610.43.02

echo "==> Removing 595 DKMS module (if present)..."
pacman -Rdd --noconfirm nvidia-open-dkms 2>/dev/null

echo "==> Restoring 610 userspace from cache..."
US=()
for p in nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings libxnvctrl; do
  f=$(ls "$CACHE/${p}-${V}-"*-x86_64*.pkg.tar.zst 2>/dev/null | grep -v '\.sig' | head -1)
  [ -n "$f" ] && US+=("$f")
done
pacman -U --noconfirm "${US[@]}"

echo "==> Reinstalling prebuilt 610 kernel modules (from repo)..."
pacman -S --noconfirm linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open

echo "==> Removing the IgnorePkg pin if present..."
sed -i '/^IgnorePkg = nvidia-open-dkms/d' /etc/pacman.conf 2>/dev/null

echo "==> Rebuilding initramfs / Limine..."
limine-update
echo
echo "✅ Rolled back to 610.43.02. Reboot."
