#!/usr/bin/env bash
# Roll back 580-proprietary  ->  610-open (the known-working CUDA baseline).
# Run as:  sudo bash rollback_to_610.sh
# Uses cached 610 packages; no network needed (adds -Sy fallback just in case).
set -e
CACHE=/var/cache/pacman/pkg
V=610.43.02

echo "==> Removing 580 proprietary DKMS stack..."
pacman -Rdd --noconfirm nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils opencl-nvidia-580xx 2>/dev/null || true

echo "==> Restoring 610 userspace from cache..."
US=()
for p in nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings; do
  f=$(ls "$CACHE/${p}-${V}-"*-x86_64*.pkg.tar.zst 2>/dev/null | grep -v '\.sig' | head -1)
  [ -n "$f" ] && US+=("$f")
done
if [ ${#US[@]} -gt 0 ]; then pacman -U --noconfirm "${US[@]}"; else pacman -S --noconfirm nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings; fi

echo "==> Reinstalling prebuilt 610 kernel modules..."
pacman -S --noconfirm linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open

echo "==> Rebuilding initramfs / Limine..."
limine-update
echo
echo "Rolled back to 610.43.02 (open). COLD poweroff -> wait 30s -> power on."
