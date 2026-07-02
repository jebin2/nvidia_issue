#!/usr/bin/env bash
# Fix the VFS/unknown-block(0,0) panic: rebuild initramfs + Limine config
# cleanly from the REAL system (chroot from a snapshot boot).
# Run as: sudo bash fix_boot.sh
set -e
UUID=fd759822-1930-4fee-a692-d1086c16595e
R=/mnt/realroot

echo "==> [1/3] Mounting the real system (/@)..."
mkdir -p $R
mountpoint -q $R || mount -o subvol=/@ UUID=$UUID $R
mountpoint -q $R/boot || mount /dev/nvme0n1p1 $R/boot

echo "==> [2/3] Rebuilding initramfs + Limine config inside the real system..."
if command -v arch-chroot >/dev/null 2>&1; then
  arch-chroot $R bash -c 'dkms status | grep -i nvidia; mkinitcpio -P && limine-update'
else
  for d in dev proc sys run; do mount --rbind /$d $R/$d && mount --make-rslave $R/$d; done
  chroot $R bash -c 'dkms status | grep -i nvidia; mkinitcpio -P && limine-update'
fi

echo "==> [3/3] Done."
echo "Reboot and pick the NORMAL 'linux-cachyos-lts' entry (not Snapshots)."
