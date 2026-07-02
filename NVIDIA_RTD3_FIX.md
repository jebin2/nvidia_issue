# NVIDIA dGPU Crash Fix — RTD3 Resume Failure (Optimus / RTX 4050 Laptop)

**Status:** ✅ Fixed and verified on 2026-06-29
**Machine:** CachyOS (Arch-based), kernel 7.1.1-2-cachyos, Limine bootloader
**GPU:** NVIDIA GeForce RTX 4050 Laptop GPU (`10de:28e1`, Ada Lovelace), VBIOS `95.07.19.00.25`
**iGPU:** Intel `8086:4688` (hybrid / Optimus)
**Driver:** NVIDIA **open** kernel module `610.43.02` (`linux-cachyos-nvidia-open`)

---

## Symptom

Frequent "NVIDIA errors" / GPU hangs. Kernel log flooded with thousands of:

```
NVRM: kbusVerifyBar2_GM107: L2 evict failed
```

Once it happens the GPU falls off the PCIe bus and **`nvidia-smi` and even `lspci` hang unkillably** (process stuck in `D` state on `os_acquire_rwlock_read`). `runtime_status` gets stuck at `resuming`. Only a reboot recovers it.

> Note: the `GM107` in the message is just NVIDIA's internal HAL function name. It is **not** an old Maxwell card — the GPU is a modern Ada RTX 4050.

## Root cause

**RTD3 runtime power management.** The dGPU auto-suspends to deep power-off (D3cold) when idle (`/sys/bus/pci/devices/0000:01:00.0/power/control = auto`, driver default `DynamicPowerManagement = 2`). On resume, BAR2 memory-map verification fails (`L2 evict failed`), the GPU never comes back, and it drops off the bus. This is a known RTD3 instability on Ada laptops with the open module.

## The fix

Disable RTD3 by forcing `NVreg_DynamicPowerManagement=0`.

### ⚠️ Why `/etc/modprobe.d` does NOT work here

`nvidia` is **force-loaded early from the initramfs** via
`/etc/mkinitcpio.conf.d/10-chwd.conf`:

```
MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
```

That early load path ignores `/etc/modprobe.d/nvidia-pm.conf`. After trying it,
`grep -i dynamic /proc/driver/nvidia/params` still showed `DynamicPowerManagement: 2`.

### ✅ Working method — kernel command line (Limine)

```bash
# 1. Append the parameter to the Limine cmdline source
echo 'KERNEL_CMDLINE[default]+=" nvidia.NVreg_DynamicPowerManagement=0"' | sudo tee -a /etc/default/limine

# 2. Regenerate Limine boot entries + initramfs
sudo limine-update

# 3. Reboot
reboot
```

> On this system `mkinitcpio -P` redirects to `limine-mkinitcpio`; `limine-update` does both the EFI entry update and the initramfs rebuild.

### One-time wedge recovery (cold boot, not warm)

If the GPU is already wedged, a **warm reboot does NOT clear it** — the dGPU isn't
power-cycled and comes back with a GSP firmware-boot timeout:

```
NVRM: Xid (PCI:0000:01:00): 120, GSP task exception: load access page fault
NVRM: GPU0 gpuWaitForGfwBootComplete_TU102: GSP failed to halt with GFW_BOOT
NVRM: GPU0 RmInitAdapter: Cannot initialize GSP firmware RM
NVRM: ... gpuHandleSanityCheckRegReadError_GM107   (×50k)
```

Do a **full cold power-off** (shut down, wait ~30 s, power on) to reset the GPU.

## Verification (post-fix, clean boot)

```bash
grep -i dynamic /proc/driver/nvidia/params
cat /proc/cmdline
echo "status=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
nvidia-smi --query-gpu=name,driver_version,pstate,temperature.gpu --format=csv
```

Expected / confirmed result:

| Check | Want | Got |
|-------|------|-----|
| `DynamicPowerManagement` | `0` | `0` ✅ |
| cmdline contains `nvidia.NVreg_DynamicPowerManagement=0` | yes | yes ✅ |
| `power/runtime_status` | `active` | `active` ✅ |
| `L2 evict` / `Xid` / `RmInitAdapter` count this boot | 0 | 0 ✅ |
| `nvidia-smi` | works | RTX 4050, P8, 56 °C ✅ |

> `pstate P8` is normal idle clocks — the GPU still down-clocks to save power; it
> just no longer does the deep D3cold suspend that was failing to resume.

## Fallbacks if errors ever return

1. Add `pcie_aspm=off` the same way (append to `/etc/default/limine`, `limine-update`, reboot) — for residual GFW-boot-timeout hiccups.
2. Switch from the open module (`linux-cachyos-nvidia-open`) to the proprietary `linux-cachyos-nvidia`.

## Files changed

- `/etc/default/limine` — added `nvidia.NVreg_DynamicPowerManagement=0` to `KERNEL_CMDLINE[default]`
- `/etc/modprobe.d/nvidia-pm.conf` — created earlier; **ineffective** here (kept as documentation, harmless)

## 24-hour monitoring

See `.nvidia-monitor/monitor.log` in this directory for the stability watch results.
