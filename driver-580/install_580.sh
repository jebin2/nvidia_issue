#!/usr/bin/env bash
# Swap NVIDIA 610-open  ->  580-proprietary (DKMS), to try to fix the dGPU Vulkan/GSP crash.
# Run as:  sudo bash install_580.sh
# Reversible with rollback_to_610.sh (610 pkgs stay in pacman cache).
set -e

echo "==> [1/5] Refreshing package databases..."
pacman -Sy --noconfirm

echo "==> [2/5] Removing 610 prebuilt kernel modules..."
pacman -Rdd --noconfirm linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open 2>/dev/null || true

echo "==> [3/5] Removing 610 userspace (will be replaced by 580)..."
pacman -Rdd --noconfirm nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings 2>/dev/null || true

echo "==> [4/5] Installing 580.173.02 PROPRIETARY DKMS stack..."
rm -f /usr/share/vulkan/icd.d/nvidia_icd.json.disabled   # stale renamed ICD from 610; 580 ships its own
pacman -S --noconfirm nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils opencl-nvidia-580xx

echo "==> [5/5] Verifying DKMS build + rebuilding initramfs/Limine..."
dkms status | grep -i nvidia || true
limine-update

echo
echo "================================================================"
echo " DKMS status above must show nvidia-580xx ... installed."
echo " Now do a FULL COLD POWEROFF (not reboot):"
echo "     sudo systemctl poweroff   ->  wait 30s  ->  power on"
echo
echo " If the screen is black / no GPU after boot on the 7.1 kernel,"
echo " pick the 6.18 LTS kernel in the boot menu instead."
echo "================================================================"
