#!/usr/bin/env bash
# Software power-cycle of the wedged dGPU (true D3cold via ACPI), no reboot needed.
# Run as: sudo bash gpu_powercycle.sh
set -u
GPU=0000:01:00.0
AUD=0000:01:00.1
BRIDGE=0000:00:01.0

echo "==> [1/6] Unloading nvidia modules..."
systemctl stop nvidia-persistenced 2>/dev/null
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>&1 || {
  echo "!! Could not unload modules (something is using the GPU)."
  echo "   lsof output:"; lsof /dev/nvidia* 2>/dev/null | head
  exit 1
}

echo "==> [2/6] Removing GPU + audio function from PCI..."
echo 1 > /sys/bus/pci/devices/$AUD/remove 2>/dev/null
echo 1 > /sys/bus/pci/devices/$GPU/remove

echo "==> [3/6] Letting the PCIe bridge power down the slot (D3cold)..."
echo auto > /sys/bus/pci/devices/$BRIDGE/power/control
sleep 12
echo "    bridge runtime_status: $(cat /sys/bus/pci/devices/$BRIDGE/power/runtime_status)"

echo "==> [4/6] Waking bridge + rescanning bus..."
echo on > /sys/bus/pci/devices/$BRIDGE/power/control
sleep 2
echo 1 > /sys/bus/pci/rescan
sleep 3

echo "==> [5/6] GPU back on bus?"
lspci -s 01:00.0 || { echo "!! GPU did not reappear"; exit 1; }

echo "==> [6/6] Reloading nvidia driver..."
modprobe nvidia nvidia_uvm nvidia_modeset nvidia_drm
sleep 2
nvidia-smi --query-gpu=name,driver_version,temperature.gpu --format=csv,noheader
