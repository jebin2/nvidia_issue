#!/usr/bin/env bash
# Slim the initramfs: drop the forced early-load of nvidia modules (+firmware),
# which bloated the image from 242MB to 315MB and broke Limine module loading.
# nvidia will load normally from the root fs via udev instead (display is Intel).
# Run as: sudo bash fix_boot2.sh   (from the snapshot boot)
set -e
UUID=fd759822-1930-4fee-a692-d1086c16595e
R=/mnt/realroot

echo "==> [1/4] Mounting the real system..."
mkdir -p $R
mountpoint -q $R || mount -o subvol=/@ UUID=$UUID $R
mountpoint -q $R/boot || mount /dev/nvme0n1p1 $R/boot

echo "==> [2/4] Current chwd drop-in (for the record):"
cat $R/etc/mkinitcpio.conf.d/10-chwd.conf

echo "==> [3/4] Overriding: no early nvidia in initramfs..."
cat > $R/etc/mkinitcpio.conf.d/99-no-early-nvidia.conf <<'EOF'
# Override 10-chwd.conf: do NOT bake nvidia modules+firmware into the initramfs.
# The display runs on the Intel iGPU; nvidia loads from the root fs via udev.
# This keeps the initramfs small enough for Limine and makes modprobe.d effective.
MODULES=()
EOF

echo "==> [4/4] Rebuilding initramfs + Limine config in the real system..."
for d in dev proc sys run; do
  mountpoint -q $R/$d || { mount --rbind /$d $R/$d && mount --make-rslave $R/$d; }
done
chroot $R limine-mkinitcpio
echo
echo "==> New sizes:"
ls -la /boot/0f701ba98a0341bc83373b7966960a51/linux-cachyos-lts/ /boot/0f701ba98a0341bc83373b7966960a51/linux-cachyos/ 2>/dev/null | grep -E 'initramfs|vmlinuz'
echo
echo "Done. Reboot -> pick NORMAL linux-cachyos-lts (not Snapshots)."
